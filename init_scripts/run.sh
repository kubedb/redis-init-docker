#!/bin/sh

if [ "$REDIS_TYPE" = "Cluster" ]; then
    cp /tmp/scripts/cluster/$MAJOR_REDIS_VERSION/* /scripts
    cp /tmp/scripts/redis-node-finder /scripts/
elif [ "$REDIS_TYPE" = "Sentinel" ]; then
    cp /tmp/scripts/sentinel/* /scripts
fi
