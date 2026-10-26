#!/bin/bash
# check_deploy_drift.sh — is every running crunchtools container on the image
# its registry tag points at now?
#
# WHY THIS EXISTS. Registry drift answers "did the release reach Quay and
# GHCR?". Nothing asked the last question, "did it reach lotor?". The weekend
# report of 2026-10-24 found mcp-systemd, mcp-podman and mcp-notebooklm a
# release or two behind with every check green. All three units ran :latest
# without the io.containers.autoupdate=registry label, so
# podman-auto-update.timer never touched them, and a release landed only when
# someone restarted the unit by hand. Nobody did. postfix had been in the same
# state since May.
#
# WHAT IT FINDS, per running container whose image is quay.io/crunchtools/*:
#
#   unmanaged  pulled by tag, no autoupdate=registry label. Releases never
#              land. Fix: add the label to the unit, in /srv and /etc.
#   stale      autoupdate is on, but the running digest is not the one the tag
#              has on Quay, and Quay moved that tag more than GRACE_HOURS ago.
#              Auto-update is failing. Fix: read the podman-auto-update.service
#              journal.
#
# An image pinned by digest (@sha256:) is a deliberate choice -- kagemusha pins
# one so what it runs changes only when its unit does -- so it is counted in
# the perfdata and never reported as drift. Third-party images are not ours to
# police and are ignored.
#
# GRACE_HOURS defaults to 30. podman-auto-update.timer fires once a day at
# 03:00 ET (the maintenance-window drop-in), so a tag pushed at 03:01
# legitimately waits ~24h. Anything older than that missed a run.
#
# WARNING, never CRITICAL: drift is a process defect, not an outage, and hermes
# pages on CRITICAL only.
#
# HONESTY RULE (RT #1481, RT #1488). A comparison that did not happen is never
# OK. Unreadable containers are counted and named, with the same policy as
# check_registry_drift.sh: UNKNOWN when nothing drifted but something was
# unreadable, or when more than half was; otherwise report the drift found with
# the unreadable count in the headline.
#
# Usage: check_deploy_drift.sh [grace_hours]

set -uo pipefail

GRACE_HOURS=${1:-30}
SOCK=${PODMAN_SOCK:-/run/podman/podman.sock}
QUAY_API=${QUAY_API:-https://quay.io/api/v1}
NET_TIMEOUT=${DEPLOY_DRIFT_TIMEOUT:-15}
PREFIX="quay.io/crunchtools/"

OK=0; WARNING=1; UNKNOWN=3

if ! [[ "$GRACE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "DEPLOY DRIFT UNKNOWN - grace_hours must be a whole number"
    exit $UNKNOWN
fi

ids=$(curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/libpod/containers/json") || {
    echo "DEPLOY DRIFT UNKNOWN - cannot list containers on ${SOCK}"
    exit $UNKNOWN
}
ids=$(printf '%s' "$ids" | grep -oP '"Id":"\K[0-9a-f]{64}')
[ -n "$ids" ] || {
    echo "DEPLOY DRIFT UNKNOWN - podman listed no running containers"
    exit $UNKNOWN
}

# One container in, one verdict line out. Workers run concurrently and each
# prints a single short line, so the verdicts cannot interleave.
check_one() {
    local id=$1 raw name ref auto have img tag body want start
    raw=$(curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
        "http://localhost/v5.0.0/libpod/containers/${id}/json") || {
        printf 'UNKNOWN %s\n' "${id:0:12}"; return
    }
    name=$(printf '%s' "$raw" | grep -oP '"Name":\s*"\K[^"]+' | head -1)
    ref=$(printf '%s' "$raw" | grep -oP '"ImageName":\s*"\K[^"]+' | head -1)
    case "$ref" in "$PREFIX"*) ;; *) printf 'IGNORED\n'; return ;; esac
    case "$ref" in *@sha256:*) printf 'PINNED\n'; return ;; esac

    auto=$(printf '%s' "$raw" | grep -oP '"io\.containers\.autoupdate":\s*"\K[^"]+' | head -1)
    if [ "$auto" != "registry" ]; then
        printf 'UNMANAGED %s\n' "$name"; return
    fi

    have=$(printf '%s' "$raw" | grep -oP '"ImageDigest":\s*"\K[^"]+' | head -1)
    img=${ref#"$PREFIX"}; tag=latest
    case "$img" in *:*) tag=${img##*:}; img=${img%:*} ;; esac

    body=$(curl -sf --max-time "$NET_TIMEOUT" \
        "${QUAY_API}/repository/crunchtools/${img}/tag/?specificTag=${tag}&onlyActiveTags=true") || {
        printf 'UNKNOWN %s\n' "$name"; return
    }
    want=$(printf '%s' "$body" | grep -oP '"manifest_digest":\s*"\K[^"]+' | head -1)
    start=$(printf '%s' "$body" | grep -oP '"start_ts":\s*\K[0-9]+' | head -1)
    if [ -z "$want" ] || [ -z "$start" ] || [ -z "$have" ]; then
        printf 'UNKNOWN %s\n' "$name"; return
    fi

    if [ "$have" = "$want" ] || [ $(( $(date +%s) - start )) -lt $((GRACE_HOURS * 3600)) ]; then
        printf 'CLEAN\n'
    else
        printf 'STALE %s\n' "$name"
    fi
}
export -f check_one
export SOCK QUAY_API NET_TIMEOUT PREFIX GRACE_HOURS

results=$(printf '%s\n' "$ids" | xargs -P "${DEPLOY_DRIFT_JOBS:-8}" -L1 bash -c 'check_one "$@"' _ | sort)

unmanaged=""; stale=""; unknown=""; clean=0; pinned=0

while read -r kind value; do
    case "$kind" in
        CLEAN)     clean=$((clean + 1)) ;;
        PINNED)    pinned=$((pinned + 1)) ;;
        UNMANAGED) unmanaged="$unmanaged $value" ;;
        STALE)     stale="$stale $value" ;;
        UNKNOWN)   unknown="$unknown $value" ;;
    esac
done <<< "$results"

n_unmanaged=$(printf '%s' "$unmanaged" | wc -w)
n_stale=$(printf '%s' "$stale" | wc -w)
n_unknown=$(printf '%s' "$unknown" | wc -w)
drift=$((n_unmanaged + n_stale))
total=$((drift + n_unknown + clean))

perf="unmanaged=${n_unmanaged};;;0 stale=${n_stale};;;0 clean=${clean};;;0 unknown=${n_unknown};;;0 pinned=${pinned};;;0"

detail=""
[ -n "$unmanaged" ] && detail="${detail}unmanaged (no autoupdate label):${unmanaged}. "
[ -n "$stale" ] && detail="${detail}stale (auto-update not applying):${stale}. "
[ -n "$unknown" ] && detail="${detail}unreadable:${unknown}. "

if [ "$n_unknown" -gt 0 ] && [ "$drift" -eq 0 ]; then
    echo "DEPLOY DRIFT UNKNOWN - ${n_unknown}/${total} containers could not be checked. ${detail}| $perf"
    exit $UNKNOWN
fi

if [ "$n_unknown" -gt $((total / 2)) ]; then
    echo "DEPLOY DRIFT UNKNOWN - ${n_unknown}/${total} containers could not be checked, too many to trust the rest. ${detail}| $perf"
    exit $UNKNOWN
fi

if [ "$drift" -eq 0 ]; then
    echo "DEPLOY DRIFT OK - ${clean}/${total} containers run the image their tag points at | $perf"
    exit $OK
fi

blind=""
[ "$n_unknown" -gt 0 ] && blind=", ${n_unknown} UNCHECKED"
echo "DEPLOY DRIFT WARNING - ${drift}/${total} containers drifted: ${n_unmanaged} unmanaged, ${n_stale} stale${blind}. ${detail}| $perf"
exit $WARNING
