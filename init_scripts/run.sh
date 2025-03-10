#!/bin/sh

if [ "$REDIS_MODE" = "Cluster" ]; then
    cp /tmp/scripts/cluster/valkey-cli/* /scripts
    cp /tmp/scripts/redis-node-finder /scripts/
elif [ "$REDIS_MODE" = "Sentinel" ]; then

    cp /tmp/scripts/sentinel/* /scripts
    cp /tmp/scripts/redis-node-finder /scripts/
elif [ "$REDIS_MODE" = "Standalone" ]; then

    cp /tmp/scripts/standalone/* /scripts
fi
