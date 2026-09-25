#!/bin/sh

# Detaches a branched cluster member's cloned nodes.conf from the source cluster:
# peers keep their ID, role and slots but lose their address, so only the branch's own pods get met.
# No-op unless BRANCH_ID is set; runs once per branch (marker file).
detachBranchedNodesConf() {
    [ -n "${BRANCH_ID:-}" ] || return 0
    data_dir="${1:-/data}"
    conf="$data_dir/nodes.conf"
    marker="$data_dir/.kubedb-branch-id"
    if [ ! -f "$conf" ]; then
        log "BRANCH" "no nodes.conf, nothing to detach"
        return 0
    fi
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$BRANCH_ID" ]; then
        log "BRANCH" "nodes.conf already detached for this branch"
        return 0
    fi
    if ! awk '
$1 == "vars" || NF < 8 { print; next }
$3 ~ /(^|,)myself(,|$)/ { print; next }
{
    n = split($2, addr, ",")
    out = ":0@0"
    if (n >= 2) out = out ","
    for (i = 3; i <= n; i++) out = out "," addr[i]
    $2 = out

    nf = split($3, flags, ",")
    keep = ""
    for (i = 1; i <= nf; i++) {
        f = flags[i]
        if (f == "fail" || f == "fail?" || f == "handshake" || f == "noaddr") continue
        keep = keep f ","
    }
    $3 = keep "noaddr"
    $5 = 0
    $6 = 0
    $8 = "disconnected"
    print
}
' "$conf" >"$conf.branch-prep"; then
        rm -f "$conf.branch-prep"
        return 1
    fi
    mv "$conf.branch-prep" "$conf" || return 1
    printf '%s' "$BRANCH_ID" >"$marker" || return 1
    log "BRANCH" "detached nodes.conf from the source cluster"
}
