#!/bin/bash
function timestamp() {
    date +"%Y/%m/%d %T"
}
function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$type] $msg"
}
function waitForPong() {
    log "INFO" "Trying to PING $HOSTNAME.$GOVERNING_SERVICE"
    while true; do
        if [[ "${TLS:-0}" == "ON" ]]; then
            out=$(timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt ping)
        else
            out=$(timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 ping)
        fi
        if [[ "$out" == "PONG" ]]; then
            break
        fi
        echo -n .
        sleep 1
    done
    log "INFO" "Succefully Get PONG from $HOSTNAME.$GOVERNING_SERVICE"
}

function resetSentinel() {
    log "INFO"  "resetting Sentinel $HOSTNAME..."
    waitForPong
    if [[ "${TLS:-0}" == "ON" ]]; then
        timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL RESET "*"
    else
        timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 SENTINEL RESET "*"
    fi
}

function setSentinelConf() {
    echo "sentinel announce-ip $HOSTNAME.$GOVERNING_SERVICE" >>/data/sentinel.conf
    echo "requirepass $REDISCLI_AUTH" >>/data/sentinel.conf
    echo "masterauth $REDISCLI_AUTH" >>/data/sentinel.conf
}

flag=1
not_exists_dns_entry() {
    myip=$(hostname -i)
    if [[ -z "$(getent ahosts "$GOVERNING_SERVICE" | grep "^${myip}")" ]]; then
        log "WARNING" "$GOVERNING_SERVICE does not contain the IP of this pod: ${myip}"
        flag=1
    else
        echo "$GOVERNING_SERVICE has my IP: ${myip}"
        flag=0
    fi
}

while [[ flag -ne 0 ]]; do
    not_exists_dns_entry
    sleep 1
done
args=$@
# if /data/sentinel.conf file not available
if [[ ! -f /data/sentinel.conf ]]; then
    cp /scripts/sentinel.conf /data/sentinel.conf
    setSentinelConf
    exec redis-sentinel /data/sentinel.conf $args
else
    exec redis-sentinel /data/sentinel.conf $args &
    pid=$!
    resetSentinel
    wait $pid
fi
