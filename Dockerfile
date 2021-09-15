FROM alpine

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
ENTRYPOINT ["/init_scripts/run.sh"]
