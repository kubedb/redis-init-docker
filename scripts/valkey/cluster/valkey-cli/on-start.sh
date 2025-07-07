#!/bin/sh

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

splitValkeyAddress() {
    node_identity=$1
    IFS=' '
    cur_address=$POD_IP
    cur_port="6379"
    cur_busport="16379"

    set -- $node_identity
    cur_podname=$1
    cur_address=$2
    cur_port=$3
    cur_busport=$4
    if [ "$endpoint_type" = "$default_endpoint_type" ]
    then
        cur_ip="$2"
    else
        cur_ip="$5"
    fi
}

getValkeyAddress() {
    pod_name="$1"
    IFS=$(echo "\n\b")
    while read -r vk_node; do
        splitValkeyAddress "$vk_node"
        if [ "$cur_podname" = "$pod_name" ]; then
            break
        fi
    done < "/tmp/$valkey_endpoints"

    if [ "$cur_podname" != "$pod_name" ]; then
        unset cur_podname
        unset cur_address
        unset cur_port
        unset cur_busport
        unset cur_ip
    fi
}

loadOldNodesConfIfExist() {
    unset old_nodes_conf
    if [ -e /data/nodes.conf ]; then
        log "CLUSTER" "Old nodes.conf found. loading"
        old_nodes_conf=$(cat /data/nodes.conf)
        log "Old nodes .conf" "$old_nodes_conf"
        old_master_cnt=$(echo "$old_nodes_conf" | tr " " "\n" | grep -c "master")
        log "Old nodes.conf" "Master Count : $old_master_cnt"
        if [ "$old_master_cnt" -lt 3 ]; then
            log "CLUSTER" "Discarding OLD Cluster Info. Not sufficient info to recover"
            unset old_nodes_conf
        fi
    else
        log "CLUSTER" "Old nodes.conf NOT found"
    fi
}
# Finds master count, replica count and dns of pods
# redis-node-finder binary gets updated master and replica count and write the data in /tmp directory
# We read those data from /tmp directory and use them
getDataFromRedisNodeFinder() {
    master_file_name="master-count.txt"
    slave_file_name="slave-count.txt"
    valkey_endpoints="db-endpoints.txt"
    initial_master_nodes_file_name="initial-master-nodes.txt"
    endpoint_type_file_name="endpoint-type.txt"
    cd /scripts && ./redis-node-finder run --mode="cluster" --master-file="$master_file_name" --slave-file="$slave_file_name" --nodes-file="$valkey_endpoints" --initial-master-file="$initial_master_nodes_file_name" --endpoint-type-file="$endpoint_type_file_name"
    MASTER=$(cat "/tmp/$master_file_name")
    REPLICAS=$(cat "/tmp/$slave_file_name")
    valkey_nodes=$(cat "/tmp/$valkey_endpoints")
    initial_master_nodes=$(cat "/tmp/$initial_master_nodes_file_name")
    endpoint_type=$(cat "/tmp/$endpoint_type_file_name")
    log "VALKEY" "${valkey_nodes}"
    log "VALKEY" "Master : $MASTER , Slave : $REPLICAS"
}
setupInitialThings() {
    script_name=${0##*/}

    readonly node_flag_master="master"
    readonly node_flag_slave="slave"
    readonly node_flag_myself="myself"
    readonly default_endpoint_type="ip"

    loadOldNodesConfIfExist
    getDataFromRedisNodeFinder

    getValkeyAddress $HOSTNAME
    readonly valkey_node_info=$vk_node
    readonly valkey_address=$cur_address
    readonly valkey_database_port=$cur_port
    readonly valkey_busport=$cur_busport

    setUpValkeyArgs
}

checkIfValkeyServerIsReady() {
    node_info="$1"
    splitValkeyAddress "$node_info"
    is_current_valkey_server_running=false

    RESP=$(valkey-cli -h "$cur_address" -p "$cur_port" $valkey_args ping 2>/dev/null)
    if [ "$RESP" = "PONG" ]; then
        is_current_valkey_server_running=true
    fi
}
# Updating nodes_conf var which contains cluster nodes. the argument is exec node, executing which we get cluster nodes
update_nodes_conf() {
    valkey_info="$1"
    checkIfValkeyServerIsReady "$valkey_info"
    unset nodes_conf
    if [ "$is_current_valkey_server_running" = true ]; then
        splitValkeyAddress "$valkey_info"
        nodes_conf=$(valkey-cli -h "$cur_address" -p "$cur_port" $valkey_args cluster nodes)
    fi
}
# Wait for current valkey servers discovered by node-finder to be up and ready to accept connections and form cluster
# We will try to ping each node for maxTimeout time and then try next one
waitForAllValkeyServersToBeReady() (
    log "INFO" "Wait for $1s for each valkey server to be ready"
    maxTimeout=$1

    IFS=$(echo "\n\b")
    while read -r vk_node; do
        endTime=$(($(date +%s) + maxTimeout))
        while [ "$(date +%s)" -lt $endTime ]; do
            checkIfValkeyServerIsReady "$vk_node"
            if [ "$is_current_valkey_server_running" = true ]; then
                break
            fi
            sleep 1
        done
    done < "/tmp/$valkey_endpoints"
)
# contains(string, substring)
#
# Returns 0 if the specified string contains the specified substring,
# otherwise returns 1.
contains() {
    string="$1"
    substring="$2"
    if test "${string#*$substring}" != "$string"; then
        return 0 # $substring is in $string
    else
        return 1 # $substring is not in $string
    fi
}
# checkCurrentNodesStatus() function takes a domain name and node_flag as parameter
# and checks if that flag exist on the node
checkCurrentNodesStatus() {
    current_host="$1"
    node_flag="$2"
    update_nodes_conf "$current_host"
    unset current_nodes_checked_status
    temp_file=$(mktemp)
    printf '%s\n' "$nodes_conf" >"$temp_file"
    if [ -e "$temp_file" ]; then
        current_nodes_checked_status=false
        while IFS= read -r line; do
            if contains "$line" "$node_flag" && contains "$line" "$node_flag_myself"; then
                current_nodes_checked_status=true
            fi
        done <"$temp_file"
    fi
    rm "$temp_file"
}

countFlagInNodesConf() {
    host="$1"
    flag="$2"
    update_nodes_conf "$host"
    unset given_flag_count
    if [ -n "$nodes_conf" ]; then
        given_flag_count=$(echo "$nodes_conf" | tr " " "\n" | grep -c "$flag")
    fi
}
countMasterInNodeConf() {
    countFlagInNodesConf "$1" "$node_flag_master"
    unset cluster_master_cnt
    if [ -n "$given_flag_count" ]; then
        cluster_master_cnt=$given_flag_count
    fi
}
# isNodeInTheCluster function takes a dns name as argument and check it's nodes conf
# If more than master exist in cluster nodes commands that means the node is in the cluster
isNodeInTheCluster() {
    host="$1"
    unset is_current_node_in_cluster
    checkIfValkeyServerIsReady "$host"

    if [ "$is_current_valkey_server_running" = true ]; then
        countMasterInNodeConf "$host"
        if [ -n "$cluster_master_cnt" ]; then
            if [ "$cluster_master_cnt" -gt 1 ]; then
                is_current_node_in_cluster=true
            else
                is_current_node_in_cluster=false
            fi
        fi
    fi
}

# checkIfValkeyClusterExist function loops through the dns names and checks if any node knows
# anything about cluster. If no node knows then cluster does not exist
checkIfValkeyClusterExist() {
    unset does_valkey_cluster_exist
    IFS=$(echo "\n\b")
    while read -r vk_info; do
        isNodeInTheCluster "$vk_info"

        if [ -n "$is_current_node_in_cluster" ]; then
            if [ "$is_current_node_in_cluster" = true ]; then
                log "CLUSTER" "Valkey Cluster Exist"
                does_valkey_cluster_exist=true
                break
            else
                self_address="$valkey_address:$valkey_database_port@$valkey_busport"
                if [ "$self_address" != "$vk_info" ]; then
                    does_valkey_cluster_exist=false
                fi
            fi
        fi
    done < "/tmp/$valkey_endpoints"
}

#----------------------------------------------------------------"Common functions" end --------------------------------------------------------------#

#----------------------------------------------- "Initial create cluster from master node codes" -- start -----------------------------------------------------#

# A pod from each shard will be master.
# So We take ONE pod which is not slave from each shard and store it's IP:PORT in the master_nodes_ip_port array
# Initially all the 0th pod will be master, so we can iterate over them in valkey_nodes array by (REPLICA+1)*i indexes where i = 0,1,2,..
findIpPortOfInitialMasterPods() {
    master_nodes_ip_port=""
    master_nodes_count=0

    IFS=$(echo "\n\b")
    while read -r vk_master_info; do
        checkIfValkeyServerIsReady "$vk_master_info"
        if [ $is_current_valkey_server_running = false ]; then
            continue
        fi


        splitValkeyAddress "$vk_master_info"
        # If cur_node_ip_port is set. We retried IP:Port of the pod successfully.
        if [ -n "$cur_address" ]; then
            cur_node_ip_port="$cur_address:$cur_port"
            master_nodes_ip_port="$master_nodes_ip_port $cur_node_ip_port"
            master_nodes_count=$((master_nodes_count + 1))
        fi
    done < "/tmp/$initial_master_nodes_file_name"
}
#
# This function  is called initially for 0th nodes
# The pod will wait until it creates cluster or cluster is created by other node
# To create cluster it will wait upto other 0th pod from other shards is up
# then it will create cluster using all the master nodes
createClusterOrWait() {
    log "CLUSTER" "Master Node. Create Cluster or Wait"
    while true; do
        findIpPortOfInitialMasterPods
        if [ "$master_nodes_count" -eq "$MASTER" ]; then

            checkIfValkeyClusterExist
            if [ -n "$does_valkey_cluster_exist" ]; then
                if [ $does_valkey_cluster_exist = false ]; then
                    for itr in $master_nodes_ip_port; do
                        set -- "$@" "$itr"
                    done

                    RESP=$(echo "yes" | valkey-cli $valkey_args --cluster create "$@" --cluster-replicas 0)
                    sleep 5
                    log "CREATE CLUSTER" "$RESP"
                    log "CLUSTER" "Successfully created cluster. Returning "
                else
                    log "CLUSTER" "Cluster exists . Do Nothing. Returning"
                fi
                break
            fi
        fi
        sleep 2
    done
}
#------------------------------------------- "Initial create cluster from master nodes codes" -- end --------------------------------------------------------#

#---------------------------------------------- "Initially Join cluster as slave codes" -- start -----------------------------------------------------#

# findMasterNodeIds() finds valkey node IDs of using IP
getNodeIDUsingIP() {
    vk_info=$shard_master_vk_address

    unset current_node_id
    update_nodes_conf "$vk_info"

    temp_file=$(mktemp)
    printf '%s\n' "$nodes_conf" >"$temp_file"
    if [ -e "$temp_file" ]; then
        while IFS= read -r line; do
            splitValkeyAddress "$vk_info"
            if contains "$line" "$cur_ip" && contains "$line" "$cur_port"; then
                current_node_id="${line%% *}"
            fi
        done <"$temp_file"
    fi
    rm "$temp_file"
}

# For slaves nodes only, get master id of the shard.
getSelfShardMasterIpPort() {
    cur_shard_name=$(echo "$HOSTNAME" | rev | cut -c 3- | rev)
    log "SHARD" "Current Shard Name $cur_shard_name"
    unset shard_master_vk_address
    IFS=$(echo "\n\b")
    while read -r vk_info; do
        if contains "$vk_info" "$cur_shard_name"; then
            isNodeInTheCluster "$vk_info"
            checkCurrentNodesStatus "$vk_info" "$node_flag_master"
            # To be shard master, current node should be in the cluster and it should be in master node
            if [ -n "$is_current_node_in_cluster" ] && [ $is_current_node_in_cluster = true ] && [ -n "$current_nodes_checked_status" ] && [ $current_nodes_checked_status = true ]; then
                splitValkeyAddress "$vk_info"
                # If cur_node_ip_port is set. We retried IP:Port of the pod successfully.
                if [ -n "$cur_address" ]; then
                    shard_master_vk_address=$vk_info
                    break
                fi
            fi
        fi
    done < "/tmp/$valkey_endpoints"
}

# Called for slave nodes only
joinCurrentNodeAsSlave() {
    getSelfShardMasterIpPort
    if [ -n "$shard_master_vk_address" ]; then
        log "SHARD" "Current shard master ip:port@busport -> $shard_master_vk_address"
        getNodeIDUsingIP "$shard_master_vk_address"
        if [ -n "$current_node_id" ]; then
            replica_ip_port="$valkey_address:$valkey_database_port"
            splitValkeyAddress "$shard_master_vk_address"
            shard_master_ip_port="$cur_address:$cur_port"
            RESP=$(valkey-cli $valkey_args --cluster add-node "$replica_ip_port" "$shard_master_ip_port" --cluster-slave --cluster-master-id "$current_node_id")
            sleep 5
            log "ADD NODE" "$RESP"
        fi
    fi
}

# Called for slave nodes. Wait until it joins cluster.
joinClusterOrWait() {
    while true; do
        # Check if myself is in the cluster
        isNodeInTheCluster "$valkey_node_info"

        if [ -n "$is_current_node_in_cluster" ] && [ $is_current_node_in_cluster = true ]; then
            echo "Current node is inside the cluster. Returning"
            break
        fi
        checkIfValkeyClusterExist
        if [ -n "$does_valkey_cluster_exist" ] && [ $does_valkey_cluster_exist = true ]; then
            log "CLUSTER" "Joining myself as slave"
            joinCurrentNodeAsSlave
        fi
        sleep 2
    done
}
#---------------------------------------------- "Initially Join cluster as slave codes" -- end -----------------------------------------------------#

#----------------------------------------- "Cluster Recovery When Pod Restart Codes" start -------------------------------------------------------#

# When pod restarts we need to meet the new nodes as IP of pod is changed
# We check if new valkey node's ip is in old nodes.conf, if not
# we meet this node with new node.

meetWithNode() {
    vk_node="$1"
    checkIfValkeyServerIsReady "$vk_node"
    if [ $is_current_valkey_server_running = false ]; then
        log "MEET" "Server $cur_address is not running"
        return
    fi

    # If Current node ip does not exist in old nodes.conf , need to introduce them
    update_nodes_conf "$valkey_node_info"
    splitValkeyAddress "$vk_node"

    if ! contains "$old_nodes_conf" "$cur_ip" || ! contains "$old_nodes_conf" "$cur_port" || ! contains "$nodes_conf" "$cur_ip" || ! contains "$nodes_conf" "$cur_port"; then
        RESP=$(valkey-cli -c -h "$valkey_address" -p "$valkey_database_port" $valkey_args cluster meet "$cur_ip" "6379" "16379")
        log "MEET" "Meet between $HOSTNAME and $cur_podname is $RESP"
    fi
}
# First try to meet with nodes within same shard . Then try to meet with all the nodes
meetWithNewNodes() {
    waitForAllValkeyServersToBeReady 120
    # cur_shard_name=${HOSTNAME::-2}
    # Removing last two characters
    cur_shard_name=$(echo "$HOSTNAME" | rev | cut -c 3- | rev)
    log "SHARD" "Current Shard Name $cur_shard_name"
    IFS=$(echo "\n\b")
    while read -r vk_node; do
        if [ "${vk_node#"$cur_shard_name"}" != "$vk_node" ]; then
            meetWithNode "$vk_node"
        fi
    done < "/tmp/$valkey_endpoints"

    IFS=$(echo "\n\b")
    while read -r vk_node; do
        meetWithNode "$vk_node"
    done < "/tmp/$valkey_endpoints"
}

# Check if current node is master or slave
checkNodeRole() {
    unset node_role
    node_info=$(valkey-cli -h "$valkey_address" -p "$valkey_database_port" $valkey_args info | grep role)
    if [ -n "$node_info" ]; then
        node_role=$(echo "${node_info#"role:"}")
    fi

    unset node_info
    node_info=$(valkey-cli -h "$valkey_address" -p "$valkey_database_port" $valkey_args info | grep master_host)

    if [ -n "$node_info" ]; then
        self_master_ip=$(echo "${node_info#"master_host:"}")
        self_master_port=$(echo "${node_info#"master_port:"}")
        self_master_address="$self_master_ip:$self_master_port"
    fi
}

# Only for slave nodes, this function retrieves master node id ( which is 40 chars long ) , from slave's nodes.conf (valkey-cli cluster nodes)
getMasterNodeIDForCurrentSlave() {
    unset current_slaves_master_id
    update_nodes_conf "$valkey_node_info"

    temp_file=$(mktemp)
    printf '%s\n' "$nodes_conf" >"$temp_file"

    if [ -e "$temp_file" ]; then
        while IFS= read -r line; do
            # Check if current node is slave and get it's master ID
            if contains "$line" "$node_flag_myself" && contains "$line" "$node_flag_slave"; then
                current_slaves_master_id="$(echo "$line" | cut -d' ' -f4)"

                if [ "$(echo -n "$current_slaves_master_id" | wc -m)" -eq 40 ]; then
                    log "RECOVER" "My Master ID is : $current_slaves_master_id"
                else
                    log "PANIC" "MASTER ID : $current_slaves_master_id. Wrong Info"
                fi
            fi
        done <"$temp_file"
    fi
    rm "$temp_file"
    if [ -z "$current_slaves_master_id" ]; then
        log "PANIC" "COULD NOT GET MY MASTER ID "
    fi
}

# For slave nodes, sometimes after running cluster meet, valkey node's nodes.conf is updated but
# it continuously tries to ping old master. we check if the nodes has wrong info ( valkey-cli info )
# about it's master. If master_host does not match with nodes.conf, we cluster replicate
# this node with master node's id .
recoverClusterDuringPodRestart() {
    meetWithNewNodes
    while true; do
        checkNodeRole
        if [ -n "$node_role" ]; then
            break
        fi
    done

    if [ "$node_role" = "${node_flag_slave}" ]; then
        log "RECOVER" "Master Address is : $self_master_address"
        update_nodes_conf "$valkey_node_info"
        if ! contains "$nodes_conf" "$self_master_address"; then
            log "RECOVER" "Master IP or Port does not match with nodes.conf. Replicating myself again with master"
            getMasterNodeIDForCurrentSlave

            RESP=$(valkey-cli -c $valkey_args cluster replicate "$current_slaves_master_id")
            log "RECOVER" "Cluster Replicated with master . Status : $RESP"
        fi
    else
        log "MASTER" "role is $node_role. Do Nothing. Exit "
    fi
}
#-------------------------------------- "Cluster Recovery When Pod Restart Codes" end ---------------------------------------------------------#

#If master count is less or equal to one , no cluster exist . Other wise cluster exist.
#If cluster exist we want to join ourself in the cluster otherwise we create cluster
#If the node has previous nodes.conf, we cluster meet with the new IPs and recover cluster state
processValkeyNode() {
    if [ -n "$old_nodes_conf" ]; then
        log "VALKEY" "Pod restarting. Need to do CLUSTER MEET"
        recoverClusterDuringPodRestart
    else
        lastChar=$(echo -n "$HOSTNAME" | tail -c 1)
        if [ "$lastChar" = 0 ]; then
            echo "Master Node. "
            createClusterOrWait
        else
            joinClusterOrWait
        fi
    fi
}

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
                       valkey-cli -c $valkey_args --eval "$file"
                       ;;
               esac
        done
    fi
}

# --cluster-announce-ip command announces nodes ip to valkey cluster and update nodes.conf file with updated ip
# for replica failover
# Solution Taken from : https://github.com/kubernetes/kubernetes/issues/57726#issuecomment-412467053
# Valkey server is started in the background. After doing cluster works it is taken back in in the foreground again
startValkeyServerInBackground() {
    log "VALKEY" "Started Valkey Server In Background"
    cp /usr/local/etc/valkey/default.conf /data/default.conf

    # if preferred endpoint type is ip
    if [ "$endpoint_type" = "$default_endpoint_type" ]
    then
        if [ "${TLS:-0}" = "ON" ]; then
            exec valkey-server /data/default.conf --cluster-preferred-endpoint-type "${endpoint_type}" --cluster-announce-ip "${valkey_address}" --cluster-announce-tls-port "${valkey_database_port}" --cluster-announce-bus-port "${valkey_busport}" $args &
            valkey_server_pid=$!
        else
            exec valkey-server /data/default.conf --cluster-preferred-endpoint-type "${endpoint_type}" --cluster-announce-ip "${valkey_address}" --cluster-announce-port "${valkey_database_port}" --cluster-announce-bus-port "${valkey_busport}" $args &
            valkey_server_pid=$!
        fi
    else
        if [ "${TLS:-0}" = "ON" ]; then
            exec valkey-server /data/default.conf --cluster-preferred-endpoint-type "${endpoint_type}" --cluster-announce-hostname "${valkey_address}" --cluster-announce-tls-port "${valkey_database_port}" --cluster-announce-bus-port "${valkey_busport}" $args &
            valkey_server_pid=$!
        else
            exec valkey-server /data/default.conf --cluster-preferred-endpoint-type "${endpoint_type}" --cluster-announce-hostname "${valkey_address}" --cluster-announce-port "${valkey_database_port}" --cluster-announce-bus-port "${valkey_busport}" $args &
            valkey_server_pid=$!
        fi
    fi
    waitForAllValkeyServersToBeReady 120
}
# entry Point of script
runValkey() {
    log "VALKEY" "Hello. Start of Posix Shell Script. Valkey Version is 5 or 6 or 7. Using valkey-cli commands"
    setupInitialThings
    startValkeyServerInBackground
    processValkeyNode
    loadInitData

    log "VALKEY" "Bringing back valkey server in foreground. Adios"
    wait $valkey_server_pid
}
args=$*
runValkey
