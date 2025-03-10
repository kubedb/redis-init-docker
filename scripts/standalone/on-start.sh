#!/bin/sh

script_name=${0##*/}
timestamp() {
    date +"%Y/%m/%d %T"
}
log() (
    type="$1"
    msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg" | tee -a /tmp/log.txt
)
#Checks if auth password and tls certificate files exist on the node
#if yes, add them on the argument string
setUpValkeyArgs() {
    if [ "${VALKEYCLI_AUTH:-0}" != 0 ]; then
        log "ARGS" "Setting up Auth arguments"
        auth_args="-a ${VALKEYCLI_AUTH} --no-auth-warning"
    fi

    if [ "${TLS:-0}" = "ON" ]; then
        log "ARGS" "Setting up TLS arguments"
        ca_crt=/certs/ca.crt
        client_cert=/certs/client.crt
        client_key=/certs/client.key

        if [ ! -f "$ca_crt" ] || [ ! -f "$client_cert" ] || [ ! -f "$client_key" ]; then
            log "TLS is on , but $ca_crt or $client_cert or $client_key file does not exist"
            exit 1
        fi

        tls_args="--tls --cert $client_cert --key $client_key --cacert $ca_crt"
    fi
    valkey_args="$auth_args $tls_args"
}

checkIfValkeyServerIsReady() {
    host="$1"
    is_current_valkey_server_running=false

    RESP=$(valkey-cli -h "$host" -p 6379 $valkey_args ping 2>/dev/null)
    if [ "$RESP" = "PONG" ]; then
        is_current_valkey_server_running=true
    fi
}

waitForAllValkeyServersToBeReady() (
    log "INFO" "Wait for $1s for valkey server to be ready"
    maxTimeout=$1
    # shellcheck disable=SC2039
    self_dns_name="$HOSTNAME.$VALKEY_GOVERNING_SERVICE"

    endTime=$(($(date +%s) + maxTimeout))
    while [ "$(date +%s)" -lt $endTime ]; do
        checkIfValkeyServerIsReady "$self_dns_name"
        if [ "$is_current_valkey_server_running" = true ]; then
            #log "INFO" "$domain_name is up"
            break
        fi
        sleep 1
    done

)

loadInitData() {
    if [ -d "/init" ]; then
        log "INIT" "Init Directory Exists"
        waitForAllValkeyServersToBeReady 120
        cd /init || true
        for file in /init/*
        do
           case "$file" in
                   *.sh)
                       log "INIT" "Running user provided initialization shell script $file"
                       sh "$file"
                       ;;
                   *.lua)
                       log "INIT" "Running user provided initialization lua script $file"
                       valkey-cli $valkey_args --eval "$file"
                       ;;
               esac
        done
    fi
}

runValkeyServerInBackground() {

    log "VALKEY" "Started Valkey Server In Background"
    cp /usr/local/etc/valkey/default.conf /data/default.conf
    exec valkey-server /data/default.conf $args &
    valkey_server_pid=$!
}

runValkey(){

    setUpValkeyArgs
    runValkeyServerInBackground
    loadInitData

    log "VALKEY" "Bringing back valkey server in foreground. Adios"
    wait $valkey_server_pid
}

args=$*
runValkey
