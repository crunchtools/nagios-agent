#!/bin/bash
# deploy-drift-collect.sh — deploy drift reads off the NRPE hot path (7.2.0)
#
# THE PROBLEM. check_deploy_drift.sh made one Quay API call per running
# quay.io/crunchtools container on every run, inside check_nrpe's ceiling.
# Constitution XVI moves reads like that into a collector.
#
# THE SPLIT. This script lists the running containers on the podman socket,
# inspects each one and asks Quay where its tag points, 8 containers at a
# time, NET_TIMEOUT (15s) a call, inside BUDGET (120s), and writes
# deploy-drift.status. check_deploy_drift.sh judges that file, applies its
# grace_hours argument when it judges, and starts this script through
# `podman_exec.sh --detach` in nagios-agent-ctr.crunchtools.com when the file
# is older than its REFRESH (30m, under the 60m check_interval). A flock stops
# overlapping runs.
#
# WHAT IT WRITES, $STATE_DIR/deploy-drift.status, replaced atomically:
#   DDRIFT generated=<epoch> elapsed=<s>
#   DDRIFT generated=<epoch> error=list_failed|no_containers
#   DDRIFT item=<id12> seen=<epoch> kind=IGNORED|PINNED
#   DDRIFT item=<id12> seen=<epoch> kind=UNMANAGED|CURRENT|UNKNOWN name=<name>
#   DDRIFT item=<id12> seen=<epoch> kind=BEHIND name=<name> since=<epoch>
#   DDRIFT end=1
#
# CURRENT: the running digest is the one the tag has on Quay. BEHIND: it is
# not, and since is when Quay moved the tag; the plugin decides whether that
# is still inside the grace. A container keyed by id: a recreate (which is
# what podman auto-update does) gets a new id and so a fresh answer.
#
# A container whose Quay read failed this run (UNKNOWN) keeps its previous
# answer, seen and all; the plugin counts one older than its STALE as
# unreadable. A failed container listing leaves the previous file in place,
# so the plugin goes "collector stale" once it ages out rather than judging a
# fleet nobody looked at; with no previous file it records the error.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

SOCK=${PODMAN_SOCK:-/run/podman/podman.sock}
QUAY_API=${QUAY_API:-https://quay.io/api/v1}
NET_TIMEOUT=${DEPLOY_DRIFT_TIMEOUT:-15}
PREFIX="quay.io/crunchtools/"
BUDGET=${BUDGET:-120}
STATUS="$STATE_DIR/deploy-drift.status"

cl_lock deploy-drift

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

# fail <error>: record a run that could not look, unless an earlier run left
# an answer, which is kept and ages out in the plugin.
fail() {
    if [ -r "$STATUS" ]; then
        echo "deploy-drift-collect: $1, keeping the previous status file" >&2
        exit 1
    fi
    printf 'DDRIFT generated=%s error=%s\nDDRIFT end=1\n' "$START" "$1" > "$TMP/status"
    cl_publish "$TMP/status" "$STATUS"
    exit 0
}

list=$(curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/libpod/containers/json") || fail list_failed
printf '%s' "$list" | grep -oP '"Id":"\K[0-9a-f]{64}' | sort -u > "$TMP/ids"
[ -s "$TMP/ids" ] || fail no_containers

# One container in, one line out, led by its id: "<id12> <kind> [name] [since]".
# Workers run concurrently and each prints a single short line, so the lines
# cannot interleave.
check_one() {
    local id=$1 raw name ref auto have img tag body want start
    raw=$(curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
        "http://localhost/v5.0.0/libpod/containers/${id}/json") || {
        printf '%s UNKNOWN %s\n' "${id:0:12}" "${id:0:12}"; return
    }
    name=$(printf '%s' "$raw" | grep -oP '"Name":\s*"\K[^"]+' | head -1 | tr -cd 'A-Za-z0-9._-')
    [ -n "$name" ] || name=${id:0:12}
    ref=$(printf '%s' "$raw" | grep -oP '"ImageName":\s*"\K[^"]+' | head -1)
    case "$ref" in "$PREFIX"*) ;; *) printf '%s IGNORED\n' "${id:0:12}"; return ;; esac
    case "$ref" in *@sha256:*) printf '%s PINNED\n' "${id:0:12}"; return ;; esac

    auto=$(printf '%s' "$raw" | grep -oP '"io\.containers\.autoupdate":\s*"\K[^"]+' | head -1)
    if [ "$auto" != "registry" ]; then
        printf '%s UNMANAGED %s\n' "${id:0:12}" "$name"; return
    fi

    have=$(printf '%s' "$raw" | grep -oP '"ImageDigest":\s*"\K[^"]+' | head -1)
    img=${ref#"$PREFIX"}; tag=latest
    case "$img" in *:*) tag=${img##*:}; img=${img%:*} ;; esac

    body=$(curl -sf --max-time "$NET_TIMEOUT" \
        "${QUAY_API}/repository/crunchtools/${img}/tag/?specificTag=${tag}&onlyActiveTags=true") || {
        printf '%s UNKNOWN %s\n' "${id:0:12}" "$name"; return
    }
    want=$(printf '%s' "$body" | grep -oP '"manifest_digest":\s*"\K[^"]+' | head -1)
    start=$(printf '%s' "$body" | grep -oP '"start_ts":\s*\K[0-9]+' | head -1)
    if [ -z "$want" ] || [ -z "$start" ] || [ -z "$have" ]; then
        printf '%s UNKNOWN %s\n' "${id:0:12}" "$name"; return
    fi

    if [ "$have" = "$want" ]; then
        printf '%s CURRENT %s\n' "${id:0:12}" "$name"
    else
        printf '%s BEHIND %s %s\n' "${id:0:12}" "$name" "$start"
    fi
}
export -f check_one
export SOCK QUAY_API NET_TIMEOUT PREFIX

# When BUDGET runs out timeout stops xargs and its workers, and a container
# with no line is then UNKNOWN below. Workers get no copy of the lock (9>&-)
# so a straggler cannot keep the next run out.
: > "$TMP/results"
timeout "$BUDGET" xargs -P "${DEPLOY_DRIFT_JOBS:-8}" -L1 bash -c 'check_one "$@"' _ \
    < "$TMP/ids" >> "$TMP/results" 2>/dev/null 9>&-

declare -A answer=()
while read -r id rest; do
    [[ $id =~ ^[0-9a-f]{12}$ ]] || continue
    [ -z "${answer[$id]:-}" ] && answer[$id]=$rest
done < "$TMP/results"

{
    echo "DDRIFT generated=$START elapsed=$(( $(date +%s) - START ))"
    while read -r full; do
        id=${full:0:12}
        read -r kind name since <<< "${answer[$id]:-}"
        [ -n "${kind:-}" ] || { kind=UNKNOWN; name=$id; since=""; }
        line="DDRIFT item=$id seen=$START kind=$kind${name:+ name=$name}${since:+ since=$since}"
        if [ "$kind" = UNKNOWN ]; then
            # Could not look this time: keep the last real answer if there is one.
            prev=$(cl_previous "$STATUS" "^DDRIFT item=$id seen=[0-9]+ kind=(IGNORED|PINNED|UNMANAGED|CURRENT|BEHIND)( |$)" | head -1)
            [ -n "$prev" ] && line=$prev
        fi
        echo "$line"
        kind="" name="" since=""
    done < "$TMP/ids"
    echo "DDRIFT end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
