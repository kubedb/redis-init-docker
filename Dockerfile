FROM alpine

ARG TARGETOS
ARG TARGETARCH

RUN set -x \
    && apk add --no-cache ca-certificates \
    && wget -O redis-node-finder.tar.gz https://github.com/kubedb/redis-node-finder/releases/download/v0.2.0/redis-node-finder-${TARGETOS}-${TARGETARCH}.tar.gz \
    && tar xzf redis-node-finder.tar.gz \
    && chmod +x redis-node-finder-${TARGETOS}-${TARGETARCH} \
    && mv redis-node-finder-${TARGETOS}-${TARGETARCH} redis-node-finder



FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/redis-init-docker

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
COPY --from=0 /redis-node-finder /tmp/scripts/redis-node-finder

ENTRYPOINT ["/init_scripts/run.sh"]
