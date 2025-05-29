#!/bin/bash
function timestamp() {
    date +"%Y/%m/%d %T"
}
function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$type] $msg"
}

function setUpArgs() {

    if [[ "${TLS:-0}" == "ON" ]]; then
        ca_crt=/certs/ca.crt
        client_cert=/certs/client.crt
        client_key=/certs/client.key
        if [[ ! -f "$ca_crt" ]] || [[ ! -f "$client_cert" ]] || [[ ! -f "$client_key" ]]; then
            log "TLs is enabled, but $ca_crt, $client_cert or $client_key file does not exists "
            exit 1
        fi
        tls_args=("--tls --cert ${client_cert} --key ${client_key} --cacert ${ca_crt}")
    fi
    log "TLS" "${tls_args[@]}"
}

function waitForPong() {
    log "INFO" "Trying to PING $HOSTNAME.$GOVERNING_SERVICE"
    while true; do

        out=$(timeout 3 valkey-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 ${tls_args[@]} ping)
        if [[ "$out" == "PONG" ]]; then
            break
        fi
        echo -n .
        sleep 1
    done
    log "INFO" "Succefully Get PONG from $HOSTNAME.$GOVERNING_SERVICE"
}

function resetSentinel() {
    log "INFO" "resetting Sentinel $HOSTNAME..."
    waitForPong
    timeout 3 valkey-cli -h "$HOSTNAME.$GOVERNING_SERVICE" -p 26379 ${tls_args[@]} SENTINEL RESET "*"
}

function updatePassword() {
    sed -i 's/^requirepass .*/requirepass "'"$REDISCLI_AUTH"'"/' /data/sentinel.conf
    sed -i 's/^masterauth .*/masterauth "'"$REDISCLI_AUTH"'"/' /data/sentinel.conf
}
function deleteExistingHashPass(){
    sed -i '/^user default on sanitize-payload #.*$/d' /data/sentinel.conf
}

function setSentinelConf() {
    echo "sentinel announce-ip $HOSTNAME.$GOVERNING_SERVICE" >>/data/sentinel.conf
    if [[ "${VALKEYCLI_AUTH:-0}" != 0 ]]; then
        echo "requirepass $VALKEYCLI_AUTH" >>/data/sentinel.conf
        echo "masterauth $VALKEYCLI_AUTH" >>/data/sentinel.conf
    fi
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
setUpArgs
while [[ flag -ne 0 ]]; do
    not_exists_dns_entry
    sleep 1
done
args=$@
# if /data/sentinel.conf file not available
if [[ ! -f /data/sentinel.conf ]]; then
    log "DATA" "loading from /data/sentinel.conf"
    cp /scripts/sentinel.conf /data/sentinel.conf
    setSentinelConf
    exec valkey-sentinel /data/sentinel.conf $args
else
    log "DATA" "Updating conf file with new password"
    deleteExistingHashPass
    updatePassword

    exec valkey-sentinel /data/sentinel.conf $args &
    pid=$!
    resetSentinel
    wait $pid
fi
