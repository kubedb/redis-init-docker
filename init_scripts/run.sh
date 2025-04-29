#!/bin/sh
if [ "$DISTRIBUTION" = "Valkey" ]; then
    if [ "$REDIS_MODE" = "Cluster" ]; then
        cp /tmp/scripts/valkey/cluster/valkey-cli/* /scripts
        cp /tmp/scripts/redis-node-finder /scripts/
    elif [ "$REDIS_MODE" = "Sentinel" ]; then
        cp /tmp/scripts/valkey/sentinel/* /scripts
        cp /tmp/scripts/redis-node-finder /scripts/
    elif [ "$REDIS_MODE" = "Standalone" ]; then
        cp /tmp/scripts/valkey/standalone/* /scripts
    fi


elif [ "$DISTRIBUTION" = "Official" ]; then
    if [ "$REDIS_MODE" = "Cluster" ]; then
        if [ "$MAJOR_REDIS_VERSION" = "4" ]; then
            cp /tmp/scripts/redis/cluster/redis-trib/* /scripts
        else
            cp /tmp/scripts/redis/cluster/redis-cli/* /scripts
        fi
        cp /tmp/scripts/redis-node-finder /scripts/
    elif [ "$REDIS_MODE" = "Sentinel" ]; then

        cp /tmp/scripts/redis/sentinel/* /scripts
        cp /tmp/scripts/redis-node-finder /scripts/
    elif [ "$REDIS_MODE" = "Standalone" ]; then

        cp /tmp/scripts/redis/standalone/* /scripts
    fi
fi

