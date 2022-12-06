#!/bin/bash
set -eou pipefail

function timestamp() {
    date +"%Y/%m/%d %T"
}
function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$type] $msg"
}

function setUpSentinelArgs() {
  if [[ "${SENTINEL_PASSWORD:-0}" != 0 ]]; then
      log "Sentinel_Args" "Setting up Sentinel auth args"
      sentinel_auth_args=("${sentinel_auth_args[@]} -a ${SENTINEL_PASSWORD} --no-auth-warning")
  fi
  if [[ "${SENTINEL_TLS:-0}" == "ON" ]]; then
      log "Sentinel_Args" "Setting up Sentinel TLS Args"
      ca_crt=/certs/ca.crt
      client_cert=/certs/client.crt
      client_key=/certs/client.key
      if [[ ! -f "$ca_crt" ]] || [[ ! -f "$client_cert" ]] || [[ ! -f "$client_key" ]]; then
          log "TLs is enabled, but $ca_crt, $client_cert or $client_key file does not exists "
          exit 1
      fi
      sentinel_tls_args=("--tls --cert ${client_cert} --key ${client_key} --cacert ${ca_crt}")
  fi
  sentinel_args=("${sentinel_auth_args[@]} ${sentinel_tls_args[@]}")
}
function setUpRedisArgs() {
   if [[ "${REDISCLI_AUTH:-0}" != 0 ]]; then
        log "Redis_Args" "Setting up Redis auth args"
        redis_auth_args=("${redis_auth_args[@]} -a ${REDISCLI_AUTH} --no-auth-warning")
    fi
   if [[ "${TLS:-0}" == "ON" ]]; then
        log "Redis_Args" "Setting Up Redis TLS Args"
        ca_crt=/certs/ca.crt
        client_cert=/certs/client.crt
        client_key=/certs/client.key
        if [[ ! -f "$ca_crt" ]] || [[ ! -f "$client_cert" ]] || [[ ! -f "$client_key" ]]; then
            log "TLs is enabled, but $ca_crt, $client_cert or $client_key file does not exists "
            exit 1
        fi
        redis_tls_args=("--tls --cert ${client_cert} --key ${client_key} --cacert ${ca_crt}")
    fi
    redis_args=("${redis_auth_args[@]} ${redis_tls_args[@]}")
}

function setUpInitialThings() {
    setUpSentinelArgs
    setUpRedisArgs
    down=5000
    timeout=5000

    sentinel_file_name="sentinel_replicas.txt"
    cd /scripts && ./redis-node-finder run --mode="sentinel" --sentinel-file="$sentinel_file_name"
    sentinel_replica_count=$(cat "/tmp/$sentinel_file_name")

    log "Sentinel" "Sentinel Replica Count : $sentinel_replica_count"
    sentinel_quorum_val=$(((sentinel_replica_count + 1) / 2))
    cp /usr/local/etc/redis/default.conf /data/default.conf

    echo "replica-announce-ip $HOSTNAME.$REDIS_GOVERNING_SERVICE" >>/data/default.conf
}

function waitForSentinelToBeReady() {
    log "INFO" "Wait for $1.$2 sentinel to be ready!"
    while true; do
        timeout 3 redis-cli -h "$1.$2" -p 26379 ${sentinel_args[@]} ping &>/dev/null && break
        sleep 1
    done
}

function waitForRedisToBeReady() {
    log "INFO" "Wait for $1 redis to be ready"
    while true; do
        timeout 3 redis-cli -h "$1" -p 6379 ${redis_args[@]} ping &>/dev/null && break
        sleep 2
    done
}

function resetSentinel() {
    waitForSentinelToBeReady "$1" "$SENTINEL_GOVERNING_SERVICE"
    log "INFO" "Resetting Sentinel $1.$SENTINEL_GOVERNING_SERVICE"
    redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} sentinel reset "$REDIS_CLUSTER_REGISTERED_NAME" &>/dev/null
}

function removeClusterFromSpecificSentinel() {
    waitForSentinelToBeReady "$1" "$SENTINEL_GOVERNING_SERVICE"
    RESP=$(timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} SENTINEL REMOVE "$REDIS_CLUSTER_REGISTERED_NAME")

    log "SENTINEL" "Remove Master from $SENTINEL_NAME-$i : $RESP"
}
function removeMasterGroupFromAllSentinel() {
    for ((i = 0; i < $sentinel_replica_count; i++)); do
        removeClusterFromSpecificSentinel "$SENTINEL_NAME-$i"
    done
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
    log "INFO" "Checking if all sentinel's configuration are up-to-date..."
    for ((j = 0; j < $sentinel_replica_count; j++)); do
        REPLICAS_INFO_FROM_SENTINEL=$(redis-cli -h "$SENTINEL_NAME-$j".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} sentinel replicas "$REDIS_CLUSTER_REGISTERED_NAME" 2>/dev/null)
        if [[ "${#REPLICAS_INFO_FROM_SENTINEL}" == "0" ]]; then
            # if there is no replica is available yet , then again check the same sentinel, that's why j--
            log "INFO" "No replica available yet"
            resetSentinel "$SENTINEL_NAME-$j"
        else
            findSDownStateForAllReplicasInfo "$HOSTNAME.$REDIS_GOVERNING_SERVICE" "$REPLICAS_INFO_FROM_SENTINEL"
            if [ "$s_down" == "true" ]; then
                resetSentinel "$SENTINEL_NAME-$j"
            fi
        fi
        sleep 1
    done
    log "INFO" "All sentinel's configuration are up-to-date!!"

}

function addConfigurationWithSpecificSentinel() {
    waitForSentinelToBeReady "$1" "$SENTINEL_GOVERNING_SERVICE"
    log "SENTINEL" "Setting up Configuration for $1"
    RESP=$(timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} SENTINEL MONITOR $REDIS_CLUSTER_REGISTERED_NAME "$2" 6379 $sentinel_quorum_val 2>/dev/null)
    log "CONF" "Monitor Master: $RESP"
    if [[ "${REDISCLI_AUTH:-0}" != 0 ]]; then
        timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} SENTINEL SET $REDIS_CLUSTER_REGISTERED_NAME auth-pass "$REDISCLI_AUTH" &>/dev/null
    fi
    timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} sentinel set $REDIS_CLUSTER_REGISTERED_NAME failover-timeout $timeout &>/dev/null
    timeout 3 redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} sentinel set $REDIS_CLUSTER_REGISTERED_NAME down-after-milliseconds $down &>/dev/null
}

# Here we get the sentinels and tell each sentinel which master to monitor which is currently created redis
# We also set some configuration here like auth pass (if any) , failover timeout and down-after-milisecond
# This function is called only for master and only when the redis object is first initiating
function addConfigurationWithAllSentinel() {
    REDIS_MASTER_DNS=$1
    for ((i = 0; i < $sentinel_replica_count; i++)); do
        addConfigurationWithSpecificSentinel "$SENTINEL_NAME-$i" $REDIS_MASTER_DNS
    done
}


function getMasterHost() {
    log "INFO" "Trying to get master host"
    sentinel_info_command=$(timeout 3 redis-cli -h $SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} SENTINEL get-master-addr-by-name $REDIS_CLUSTER_REGISTERED_NAME 2>/dev/null)
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
    log "INFO" "Check if all sentinels are ready"
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
       INFO_FROM_SENTINEL=$(redis-cli -h "$1".$SENTINEL_GOVERNING_SERVICE -p 26379 ${sentinel_args[@]} sentinel master $REDIS_CLUSTER_REGISTERED_NAME 2>/dev/null) && break
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
# Gets all the IP address behind Redis Governing Service and check if my ip is there
# So basically we are waiting until current node is discovered by governing service
not_exists_dns_entry() {
    # Gets IP of host pod
    myip=$(hostname -i)

    log "INFO" "Check if $REDIS_GOVERNING_SERVICE contains the IP of this pod: ${myip}"
    if [[ -z "$(getent ahosts "$REDIS_GOVERNING_SERVICE" | grep "^${myip}")" ]]; then
        flag=1
    else
        log "INFO" "$REDIS_GOVERNING_SERVICE has my IP: ${myip}"
        flag=0
    fi
}

setUpInitialThings

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
    log "INFO" "Initializing Redis server for the first time..."
    self="$HOSTNAME.$REDIS_GOVERNING_SERVICE"
    if [[ $HOSTNAME == "$REDIS_NAME-0" ]]; then
        exec redis-server /data/default.conf $args &
        pid=$!
        waitForRedisToBeReady $self
        addConfigurationWithAllSentinel "$REDIS_NAME-0.$REDIS_GOVERNING_SERVICE"
    else
        while true; do
            # This is a replica node so we master should be configured by now
            # So, the sentinels should knows about master or we wait until sentinel knows about master node
            getMasterHost
            if [ "${REDIS_MASTER_PORT_NUMBER:-0}" == "6379" ]; then
                break
            fi
            sleep 2
        done
         # Wait for master node to be ready
        waitForRedisToBeReady $REDIS_MASTER_DNS
        echo "replicaof $REDIS_MASTER_DNS $REDIS_MASTER_PORT_NUMBER" >>/data/default.conf
        exec redis-server /data/default.conf $args &
        pid=$!
    fi
else
    log "INFO" "Got master info from sentinel"
    self="$HOSTNAME.$REDIS_GOVERNING_SERVICE"
    if [ "$self" != "${REDIS_MASTER_DNS:-0}" ]; then
        log "INFO" "Checking if $REDIS_MASTER_DNS ready as primary!"
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
                log "WARNING" "Need to remove the cluster and add again as master is in s_down state"
                removeClusterFromSpecificSentinel "$SENTINEL_NAME-$i"
                addConfigurationWithSpecificSentinel "$SENTINEL_NAME-$i" "$REDIS_MASTER_DNS"
            fi
        done
    fi
fi
CheckIfMasterIsNotInSDownState
waitToSyncSentinelConfig
wait $pid
