#!/bin/sh

if [ "$REDIS_MODE" = "Cluster" ]; then
    if [ "$MAJOR_REDIS_VERSION" = "4" ]; then
        cp /tmp/scripts/cluster/redis-trib/* /scripts
    else
        cp /tmp/scripts/cluster/redis-cli/* /scripts
    fi
    cp /tmp/scripts/redis-node-finder /scripts/
elif [ "$REDIS_MODE" = "Sentinel" ]; then

    cp /tmp/scripts/sentinel/* /scripts
    cp /tmp/scripts/redis-node-finder /scripts/
elif [ "$REDIS_MODE" = "Standalone" ]; then

    cp /tmp/scripts/standalone/* /scripts
fi
