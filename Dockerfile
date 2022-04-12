FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/redis-init-docker

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
ENTRYPOINT ["/init_scripts/run.sh"]
