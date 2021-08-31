#!/bin/bash

function waitForPong() {
    for j in {120..0}; do
        if [[ "${TLS:-0}" == "ON" ]]; then
            out=$(timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt ping)
        else
            out=$(timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 ping)
        fi
        echo "Trying to ping: Step='$j', '$HOSTNAME'.'$GOVERNING_SERVICE' ,  Got='$out'"
        if [[ "$out" == "PONG" ]]; then
            break
        fi
        echo -n .
        sleep 1
    done
}

function resetSentinel() {
    echo "reset Sentinel $HOSTNAME "
    waitForPong
    if [[ "${TLS:-0}" == "ON" ]]; then
        timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 --tls --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt SENTINEL RESET "*"
    else
        timeout 3 redis-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 SENTINEL RESET "*"
    fi
}

function setSentinelConf() {
    echo "sentinel announce-ip $HOSTNAME.$GOVERNING_SERVICE" >>/data/sentinel.conf
}

flag=1
not_exists_dns_entry() {
    myip=$(hostname -i)
    echo " my ip $myip"
    if [[ -z "$(getent ahosts "$GOVERNING_SERVICE" | grep "^${myip}")" ]]; then
        echo "$GOVERNING_SERVICE does not contain the IP of this pod: ${myip}"
        flag=1
    else
        echo "$GOVERNING_SERVICE has my IP: ${myip}"
        flag=0
    fi
}

while [[ flag -ne 0 ]]; do
    echo "flag =  $flag "
    not_exists_dns_entry
    sleep 1
done
args=$@
# if /data/sentinel.conf file not available
if [[ ! -f /data/sentinel.conf ]]; then
    cp /conf/sentinel.conf /data/sentinel.conf
    setSentinelConf
    exec redis-sentinel /data/sentinel.conf $args
else
    exec redis-sentinel /data/sentinel.conf $args &
    pid=$!
    resetSentinel
    wait $pid
fi
