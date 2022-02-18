#!/bin/bash
set -eou pipefail

down=5000
timeout=5000
SENTINEL_PORT=26379
SENTINEL_PASSWORD_FLAG=""
if [[ "${SENTINEL_PASSWORD_FLAG:-0}" != 0 ]]; then
    SENTINEL_PASSWORD_FLAG="-a \"$SENTINEL_PASSWORD\""
fi

sentinel_replica_count=$SENTINEL_REPLICAS
sentinel_quorum_val=$(((sentinel_replica_count + 1) / 2))
cp /usr/local/etc/redis/default.conf /data/default.conf

echo "replica-announce-ip $HOSTNAME.$REDIS_GOVERNING_SERVICE" >>/data/default.conf
function timestamp() {
    date +"%Y/%m/%d %T"
}
function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$type] $msg"
}

function waitForSentinelToBeReady() {
    log "INFO" "wait for $1.$2 sentinel to be ready!"
    while true; do
        if [[ "${TLS:-0}" == "ON" ]]; then
            timeout 3 redis-cli -h "$1.$2" -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt ping &>/dev/null && break
        else
            timeout 3 redis-cli -h "$1.$2" -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning ping &>/dev/null && break
        fi
        sleep 1
    done
}

function waitForRedisToBeReady() {
    log "INFO" "Attempting query on $1"
    while true; do
        if [[ "${TLS:-0}" == "ON" ]]; then
            timeout 3 redis-cli -h "$1" -p 6379 --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt ping 2>/dev/null && break
        else
            timeout 3 redis-cli -h "$1" -p 6379 ping 2>/dev/null && break
        fi
        sleep 2
    done
}

function resetSentinel() {
    waitForSentinelToBeReady "$1" "$SENTINEL_GOVERNING_SERVICE"
    log "INFO" "resetting sentinel $1.$SENTINEL_GOVERNING_SERVICE"
    if [[ "${TLS:-0}" == "ON" ]]; then
        redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel reset "$STATEFULSET_NAME" 2>/dev/null
    else
        redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel reset "$STATEFULSET_NAME" 2>/dev/null
    fi
}

function removeClusterFromSpecificSentinel() {
    waitForSentinelToBeReady "$1" "$SENTINEL_GOVERNING_SERVICE"
    if [[ "${TLS:-0}" == "ON" ]]; then
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL REMOVE "$STATEFULSET_NAME"
    else
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL REMOVE "$STATEFULSET_NAME"
    fi

}

function findSDownStateForAllReplicasInfo() {
    local found=0
    local name=0
    s_down="false"
    for line in $REPLICAS_INFO_FROM_SENTINEL; do
        if [[ "$line" == "name" ]]; then
            name=1
            continue
        fi

        if [[ "$name" == "1" ]]; then
            if [ "$line" == "$1:6379" ]; then
                name=2
            else
                name=0
            fi
            continue
        fi

        if [ "$name" == "2" ]; then
            if [[ "$line" == "flags" ]]; then
                found=1
                continue
            fi

            if [[ "$found" == "1" ]]; then
                state=$line
                if [[ "$state" =~ .*"s_down".* || "$state" =~ .*"o_down".* || "$state" =~ .*"disconnected".* ]]; then
                    s_down="true"
                else
                    s_down="false"
                fi
                break
            fi
        fi
    done
}

function waitToSyncSentinelConfig() {
    log "INFO" "checking if all sentinel's configuration are up-to-date..."
    for ((j = 0; j < $sentinel_replica_count; j++)); do
        if [[ "${TLS:-0}" == "ON" ]]; then
            REPLICAS_INFO_FROM_SENTINEL=$(redis-cli -h "$SENTINEL_NAME-$j".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel replicas "$STATEFULSET_NAME" 2>/dev/null)
        else
            REPLICAS_INFO_FROM_SENTINEL=$(redis-cli -h "$SENTINEL_NAME-$j".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel replicas "$STATEFULSET_NAME" 2>/dev/null)
        fi
        if [[ "${#REPLICAS_INFO_FROM_SENTINEL}" == "0" ]]; then
            # if there is no replica is available yet , then again check the same sentinel, that's why j--
            resetSentinel "$SENTINEL_NAME-$j"
        else
            findSDownStateForAllReplicasInfo "$HOSTNAME.$REDIS_GOVERNING_SERVICE" "$REPLICAS_INFO_FROM_SENTINEL"
            if [ "$s_down" == "true" ]; then
                resetSentinel "$SENTINEL_NAME-$j"
            fi
        fi
        sleep 1
    done
    log "INFO" "all sentinel's configuration are up-to-date!!"

}

function removeMasterGroupFromAllSentinel() {
    for ((i = 0; i < $sentinel_replica_count; i++)); do
        waitForSentinelToBeReady "$SENTINEL_NAME-$i" "$SENTINEL_GOVERNING_SERVICE"
        if [[ "${TLS:-0}" == "ON" ]]; then
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL REMOVE "$STATEFULSET_NAME"
        else
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL REMOVE "$STATEFULSET_NAME"
        fi
    done
}

function addConfigurationWithAllSentinel() {
    for ((i = 0; i < $sentinel_replica_count; i++)); do
        waitForSentinelToBeReady "$SENTINEL_NAME-$i" "$SENTINEL_GOVERNING_SERVICE"
        if [[ "${TLS:-0}" == "ON" ]]; then
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL MONITOR $STATEFULSET_NAME "$1" 6379 $sentinel_quorum_val
            if [[ "${REDISCLI_AUTH:-0}" != 0 ]]; then
                timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL SET $STATEFULSET_NAME auth-pass "$REDISCLI_AUTH"
            fi
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel set $STATEFULSET_NAME failover-timeout $timeout
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel set $STATEFULSET_NAME down-after-milliseconds $down
        else
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL MONITOR $STATEFULSET_NAME "$1" 6379 $sentinel_quorum_val
            if [[ "${REDISCLI_AUTH:-0}" != 0 ]]; then
                timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL SET $STATEFULSET_NAME auth-pass "$REDISCLI_AUTH"
            fi
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel set $STATEFULSET_NAME failover-timeout $timeout
            timeout 3 redis-cli -h $SENTINEL_NAME-"$i".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel set $STATEFULSET_NAME down-after-milliseconds $down
        fi
    done
}

function addConfigurationWithSpecificSentinel() {
    waitForSentinelToBeReady "$1" "$SENTINEL_GOVERNING_SERVICE"
    if [[ "${TLS:-0}" == "ON" ]]; then
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL MONITOR $STATEFULSET_NAME "$2" 6379 $sentinel_quorum_val
        if [[ "${REDISCLI_AUTH:-0}" != 0 ]]; then
            timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL SET $STATEFULSET_NAME auth-pass "$REDISCLI_AUTH"
        fi
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel set $STATEFULSET_NAME failover-timeout $timeout
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel set $STATEFULSET_NAME down-after-milliseconds $down
    else
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL MONITOR $STATEFULSET_NAME "$2" 6379 $sentinel_quorum_val
        if [[ "${REDISCLI_AUTH:-0}" != 0 ]]; then
            timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL SET $STATEFULSET_NAME auth-pass "$REDISCLI_AUTH"
        fi
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel set $STATEFULSET_NAME failover-timeout $timeout
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel set $STATEFULSET_NAME down-after-milliseconds $down
    fi
}

function getMasterHost() {
    log "INFO" "trying to get master host"
    if [[ "${TLS:-0}" == "ON" ]]; then
        sentinel_info_command=$(timeout 3 redis-cli -h $SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL get-master-addr-by-name $STATEFULSET_NAME 2>/dev/null)
    else
        sentinel_info_command=$(timeout 3 redis-cli -h $SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning SENTINEL get-master-addr-by-name $STATEFULSET_NAME 2>/dev/null)
    fi
    REDIS_SENTINEL_INFO=()
    for line in $sentinel_info_command; do
        REDIS_SENTINEL_INFO+=("$line")
    done

    if [[ "${#REDIS_SENTINEL_INFO[@]}" == "2" ]]; then
        REDIS_MASTER_DNS=${REDIS_SENTINEL_INFO[0]}
        REDIS_MASTER_PORT_NUMBER=${REDIS_SENTINEL_INFO[1]}
    fi
}

#Check if all sentinel is ready or not
#If not ready then make sure 0th redis instance as master & other redis instance as replica of 0th pod
function isReadyAllSentinel() {
    log "INFO" "check if all sentinels are ready"
    #if the number of pong == replica of sentinel , that means all sentinel is ready.
    for ((i = 0; i < $sentinel_replica_count; i++)); do
        waitForSentinelToBeReady "$SENTINEL_NAME-$i" "$SENTINEL_GOVERNING_SERVICE"
    done
}

function getState() {
    local found=0
    for line in $INFO_FROM_SENTINEL; do
        if [[ "$line" == "flags" ]]; then
            found=1
            continue
        fi

        if [[ "$found" == "1" ]]; then
            state=$line
            if [[ "$state" =~ .*"s_down".* || "$state" =~ .*"o_down".* || "$state" =~ .*"disconnected".* ]]; then
                s_down="true"
            else
                s_down="false"
            fi
            break
        fi
    done
}

# this will find the master state from a specific sentinel
function findMasterState() {
    while true; do
        if [[ "${TLS:-0}" == "ON" ]]; then
            INFO_FROM_SENTINEL=$(redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 $SENTINEL_PASSWORD_FLAG --no-auth-warning --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt sentinel master $STATEFULSET_NAME 2>/dev/null) && break
        else
            INFO_FROM_SENTINEL=$(redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p $SENTINEL_PORT $SENTINEL_PASSWORD_FLAG --no-auth-warning sentinel master $STATEFULSET_NAME 2>/dev/null) && break
        fi
    done
    getState "$INFO_FROM_SENTINEL"
}

function CheckIfMasterIsNotInSDownState() {
    while true; do
        for ((i = 0; i < $sentinel_replica_count; i++)); do
            findMasterState "$SENTINEL_NAME-$i"
            if [[ "$s_down" == "true" ]]; then
                break
            fi
        done
        if [[ "$s_down" == "false" ]]; then
            break
        fi
    done

}

flag=1
not_exists_dns_entry() {
    myip=$(hostname -i)

    log "INFO" "check if $REDIS_GOVERNING_SERVICE contains the IP of this pod: ${myip}"
    if [[ -z "$(getent ahosts "$REDIS_GOVERNING_SERVICE" | grep "^${myip}")" ]]; then
        flag=1
    else
        log "INFO" "$REDIS_GOVERNING_SERVICE has my IP: ${myip}"
        flag=0
    fi
}

while [[ flag -ne 0 ]]; do
    not_exists_dns_entry
    sleep 1
done

## as default down after ms is 5s, so we need give a sleep at new node, at-least 5s or greater time
sleep 5
isReadyAllSentinel
getMasterHost
args=$@
if [[ "${#REDIS_SENTINEL_INFO[@]}" == "0" ]]; then
    log "INFO" "initializing the redis server for the first time..."
    self="$HOSTNAME.$REDIS_GOVERNING_SERVICE"
    if [[ $HOSTNAME == "$STATEFULSET_NAME-0" ]]; then
        exec redis-server /data/default.conf $args &
        pid=$!
        waitForRedisToBeReady $self
        addConfigurationWithAllSentinel "$STATEFULSET_NAME-0.$REDIS_GOVERNING_SERVICE"
    else
        while true; do
            getMasterHost
            if [ "${REDIS_MASTER_PORT_NUMBER:-0}" == "6379" ]; then
                break
            fi
            sleep 2
        done
        waitForRedisToBeReady $REDIS_MASTER_DNS
        echo "replicaof $REDIS_MASTER_DNS $REDIS_MASTER_PORT_NUMBER" >>/data/default.conf
        exec redis-server /data/default.conf $args &
        pid=$!
    fi
else
    self="$HOSTNAME.$REDIS_GOVERNING_SERVICE"
    if [ "$self" != "${REDIS_MASTER_DNS:-0}" ]; then
        log "INFO" "checking if $REDIS_MASTER_DNS ready as primary!"
        waitForRedisToBeReady $REDIS_MASTER_DNS
        echo "replicaof $REDIS_MASTER_DNS $REDIS_MASTER_PORT_NUMBER" >>/data/default.conf
    fi
    exec redis-server /data/default.conf $args &
    pid=$!
    waitForRedisToBeReady $self
    if [ "${REDIS_MASTER_DNS:-0}" == "$self" ]; then
        for ((i = 0; i < $sentinel_replica_count; i++)); do
            findMasterState "$SENTINEL_NAME-$i"
            if [ "$s_down" == "true" ]; then
                log "WARNING" "need to remove the cluster and add again as master is in s_down state"
                removeClusterFromSpecificSentinel "$SENTINEL_NAME-$i"
                addConfigurationWithSpecificSentinel "$SENTINEL_NAME-$i" "$REDIS_MASTER_DNS"
            fi
        done
    fi
fi
CheckIfMasterIsNotInSDownState
waitToSyncSentinelConfig
wait $pid
