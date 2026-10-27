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
# COLLECTOR (7.2.0). Listing the containers and asking Quay now happens in
# deploy-drift-collect.sh, which writes deploy-drift.status; this plugin only
# judges that file, so a slow Quay can no longer time the check out. When the
# file is missing or older than REFRESH (30m, under the 60m check_interval)
# the collector is started detached through `podman_exec.sh --detach` in
# nagios-agent-ctr.crunchtools.com and the previous run's file is judged. A
# container the collector last read more than STALE (3h) ago counts as
# unreadable, and the whole check is UNKNOWN "collector stale" when the file
# is missing or older than STALE. The grace is applied here, at judging time,
# to the tag date the collector recorded, so grace_hours stays this plugin's
# argument.
#
# Usage: check_deploy_drift.sh [grace_hours]

set -uo pipefail

GRACE_HOURS=${1:-30}
SOCK=${PODMAN_SOCK:-/run/podman/podman.sock}

OK=0; WARNING=1; UNKNOWN=3

if ! [[ "$GRACE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "DEPLOY DRIFT UNKNOWN - grace_hours must be a whole number"
    exit $UNKNOWN
fi

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "DEPLOY DRIFT UNKNOWN - cannot load collector-lib.sh"; exit $UNKNOWN; }
STATUS=${STATUS:-$STATE_DIR/deploy-drift.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/deploy-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-1800}
STALE=${STALE:-10800}

cl_open DDRIFT "DEPLOY DRIFT"
case "$(cl_field error "$(grep -m1 '^DDRIFT generated=' <<< "$CL_RAW")")" in
    list_failed)   echo "DEPLOY DRIFT UNKNOWN - cannot list containers on ${SOCK}"; exit $UNKNOWN ;;
    no_containers) echo "DEPLOY DRIFT UNKNOWN - podman listed no running containers"; exit $UNKNOWN ;;
    '') ;;
    *)             echo "DEPLOY DRIFT UNKNOWN - collector reported an unrecognised error"; exit $UNKNOWN ;;
esac

now=$(date +%s)
grace=$((GRACE_HOURS * 3600))
unmanaged=""; stale=""; unknown=""; clean=0; pinned=0

while IFS= read -r line; do
    kind=$(cl_field kind "$line"); name=$(cl_field name "$line")
    seen=$(cl_field seen "$line"); since=$(cl_field since "$line")
    # An answer older than STALE is not judged: it counts as unreadable.
    if [ $(( now - ${seen:-0} )) -ge "$STALE" ]; then
        case "$kind" in IGNORED) continue ;; esac
        unknown="$unknown ${name:-$(cl_field item "$line")}(stale)"
        continue
    fi
    case "$kind" in
        CURRENT)   clean=$((clean + 1)) ;;
        BEHIND)    if [ $(( now - ${since:-0} )) -lt "$grace" ]; then clean=$((clean + 1)); else stale="$stale $name"; fi ;;
        PINNED)    pinned=$((pinned + 1)) ;;
        UNMANAGED) unmanaged="$unmanaged $name" ;;
        UNKNOWN)   unknown="$unknown $name" ;;
    esac
done < <(grep '^DDRIFT item=' <<< "$CL_RAW" | sort -t= -k5)

n_unmanaged=$(printf '%s' "$unmanaged" | wc -w)
n_stale=$(printf '%s' "$stale" | wc -w)
n_unknown=$(printf '%s' "$unknown" | wc -w)
drift=$((n_unmanaged + n_stale))
total=$((drift + n_unknown + clean))

perf="unmanaged=${n_unmanaged};;;0 stale=${n_stale};;;0 clean=${clean};;;0 unknown=${n_unknown};;;0 pinned=${pinned};;;0 collected_age=${CL_AGE}s;;${STALE}"

detail=""
[ -n "$unmanaged" ] && detail="${detail}unmanaged (no autoupdate label):${unmanaged}. "
[ -n "$stale" ] && detail="${detail}stale (auto-update not applying):${stale}. "
[ -n "$unknown" ] && detail="${detail}unreadable:${unknown}. "
[ -n "$CL_KICKED" ] && detail="${detail}${CL_KICKED# }. "

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
