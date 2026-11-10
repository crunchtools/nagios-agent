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
#   DDRIFT item=<id12> seen=<epoch> kind=DEPLOYER|CONTESTED name=<name>
#   DDRIFT item=<id12> seen=<epoch> kind=BEHIND name=<name> since=<epoch>
#   DDRIFT end=1
#
# CURRENT: the running image is the one the tag points at. BEHIND: it is not,
# and since is when Quay moved the tag; the plugin decides whether that is
# still inside the grace. A container keyed by id: a recreate (which is what
# podman auto-update does) gets a new id and so a fresh answer.
#
# "THE ONE THE TAG POINTS AT" IS NOT THE TAG'S DIGEST. Both the digest podman
# records on a container and the one Quay reports for a tag are OCI INDEX
# digests, and an index moves for reasons the image does not. A rebuild at the
# same commit re-generates the provenance ATTESTATION manifest, which is a
# child of the index, so the index digest changes while the runnable
# per-architecture manifest -- and therefore the image -- is byte for byte
# what it was. Comparing index digests alone called that drift.
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
    local id=$1 raw name ref auto have img tag body want start imgid idig
    raw=$(curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
        "http://localhost/v5.0.0/libpod/containers/${id}/json") || {
        printf '%s UNKNOWN %s\n' "${id:0:12}" "${id:0:12}"; return
    }
    name=$(printf '%s' "$raw" | grep -oP '"Name":\s*"\K[^"]+' | head -1 | tr -cd 'A-Za-z0-9._-')
    [ -n "$name" ] || name=${id:0:12}
    ref=$(printf '%s' "$raw" | grep -oP '"ImageName":\s*"\K[^"]+' | head -1)
    case "$ref" in "$PREFIX"*) ;; *) printf '%s IGNORED\n' "${id:0:12}"; return ;; esac
    case "$ref" in *@sha256:*) printf '%s PINNED\n' "${id:0:12}"; return ;; esac
    # pbs runs as one-shot backup jobs that pull their own image (--pull=newer).
    # The autoupdate label would let auto-update restart one mid-backup.
    case "$ref" in "${PREFIX}pbs:"*) printf '%s IGNORED\n' "${id:0:12}"; return ;; esac
    # The developer seats carry no autoupdate label on purpose (RT #1556,
    # Scott 2026-11-06): an agent in one runs jobs that take hours, and
    # auto-update restarting it at 03:00 destroys the work. A release lands
    # there when a seat is restarted deliberately, between jobs. Reporting
    # that as drift would leave a WARNING nobody can ever clear, and a
    # standing WARNING teaches the fleet to ignore this check -- which is the
    # exact failure it was written to catch.
    case "$ref" in "${PREFIX}developer:"*) printf '%s IGNORED\n' "${id:0:12}"; return ;; esac

    auto=$(printf '%s' "$raw" | grep -oP '"io\.containers\.autoupdate":\s*"\K[^"]+' | head -1)
    # A POSITIVE MARKER, not another image-name exception. A service in the
    # deploy robot's registry carries io.crunchtools.deploy=deployer and
    # deliberately carries no autoupdate label: it is deployed by ticket, with
    # a maintenance window, a health probe and a rollback, and auto-update
    # restarting it at 03:00 would put an unverified image live. "Behind the
    # tag" is therefore its NORMAL state and not a defect -- which is exactly
    # why the marker has to be a label on the container rather than a list of
    # images in this file. The registry grows service by service, and a check
    # that needed editing for each one would be a check that was wrong between
    # edits. check_deployer.sh is what watches these.
    mark=$(printf '%s' "$raw" | grep -oP '"io\.crunchtools\.deploy":\s*"\K[^"]+' | head -1)
    if [ "$mark" = "deployer" ]; then
        # BOTH mechanisms claiming one service is a real misconfiguration and
        # the likely mistake when onboarding: auto-update would deploy an
        # unverified image behind the robot's back, and the robot would roll
        # back something auto-update had just put there. Reported, not silently
        # resolved in favour of either one.
        if [ "$auto" = "registry" ]; then
            printf '%s CONTESTED %s\n' "${id:0:12}" "$name"; return
        fi
        printf '%s DEPLOYER %s\n' "${id:0:12}" "$name"; return
    fi
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
        printf '%s CURRENT %s\n' "${id:0:12}" "$name"; return
    fi

    # The digests disagree, which is not yet an answer -- see the header. On
    # 2026-11-07 quay.io/crunchtools/openclaw:latest was rebuilt at the same
    # commit: the new index pointed at the IDENTICAL amd64 manifest and
    # differed only in its attestation child. takeda was running the right
    # image, `podman auto-update --dry-run` said so (UPDATED false), and this
    # collector reported it BEHIND. Nothing could ever clear that, because
    # there was nothing to apply -- a permanent WARNING, which is the one
    # outcome check_deploy_drift.sh's own header says destroys a check.
    #
    # So ask podman about the image this container is ACTUALLY running: if the
    # tag's current digest is among that image's RepoDigests, podman has
    # already resolved that manifest to these exact bits, and the container is
    # current however many index digests point at them. A RepoDigest is
    # podman's own record of a manifest it pulled, so a hit is evidence rather
    # than an inference.
    #
    # One LOCAL socket call, taken only on the path that would otherwise
    # report drift: the common case is unchanged, no Quay budget is spent, and
    # a miss or a failed read still reports BEHIND. This can only ever clear
    # drift it can prove is not drift.
    imgid=$(printf '%s' "$raw" | grep -oP '"Image":\s*"\K[0-9a-f]{64}' | head -1)
    if [ -n "$imgid" ]; then
        idig=$(curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
            "http://localhost/v5.0.0/libpod/images/${imgid}/json") || idig=""
        # Anchored on the repository as well as the digest: the same digest
        # under another repository name is another image's provenance, not
        # this tag's.
        case "$idig" in
            *"\"${PREFIX}${img}@${want}\""*)
                printf '%s CURRENT %s\n' "${id:0:12}" "$name"; return ;;
        esac
    fi

    printf '%s BEHIND %s %s\n' "${id:0:12}" "$name" "$start"
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
            prev=$(cl_previous "$STATUS" "^DDRIFT item=$id seen=[0-9]+ kind=(IGNORED|PINNED|UNMANAGED|DEPLOYER|CONTESTED|CURRENT|BEHIND)( |$)" | head -1)
            [ -n "$prev" ] && line=$prev
        fi
        echo "$line"
        kind="" name="" since=""
    done < "$TMP/ids"
    echo "DDRIFT end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
