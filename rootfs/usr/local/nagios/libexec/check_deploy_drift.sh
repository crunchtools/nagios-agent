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
#   contested  the container carries BOTH io.crunchtools.deploy=deployer and
#              io.containers.autoupdate=registry. Two mechanisms own the
#              service: auto-update would put an unverified image live behind
#              the deploy robot's back, and the robot would roll back something
#              auto-update had just installed. Fix: drop one, in /srv and /etc.
#
# A container marked io.crunchtools.deploy=deployer and NOT labelled for
# auto-update is counted as deployer-managed and is never CONTAINER drift. It is
# deployed by ticket -- with a maintenance window, a health probe and one
# rollback -- so "behind what the tag points at now" is its normal state for a
# while rather than a defect. The marker is a label on the container and not a
# list of images in this file on purpose: the robot's registry grows one
# service at a time, and a check that needed editing for each one would be a
# check that was wrong in between.
#
#   undeployed  a deployer-registry service whose running image has been behind
#               the registry's :latest for more than DEPLOYER_GRACE_HOURS (24).
#               A release nobody put live: rotv sat 37 releases behind this
#               way with every check green. Fix: file (or answer) the Deploy
#               ticket for the release.
#
# The undeployed verdict is NOT read from Quay or podman here. The deployer's
# release follower (crunchtools/deployer 0.9.0) already compares every registry
# row with its :latest each hour and writes the answer to FOLLOW_STATUS, one
# line per service, with since= set to the build time of :latest whenever the
# service is behind it. That is the stateless timestamp the grace is measured
# from (constitution XVI, Drift Grace): the service has been behind at least
# since then. A row the follower could not judge (result=error) is unreadable,
# under the honesty rule below. When the follower's file is missing, truncated,
# older than FOLLOW_STALE or written by a follower older than 0.9.0, deployer
# services are not compared and the headline says so; the alarm for that is
# check_release_follow.sh's, so it is not raised twice.
#
# An image pinned by digest (@sha256:) is a deliberate choice -- kagemusha pins
# one so what it runs changes only when its unit does -- so it is counted in
# the perfdata and never reported as drift. Third-party images are not ours to
# police and are ignored.
#
# quay.io/crunchtools/pbs is ignored too: its containers are one-shot backup
# jobs that pull the image themselves with --pull=newer, and the autoupdate
# label would let auto-update restart one mid-backup.
#
# quay.io/crunchtools/developer is ignored for the same kind of reason: the
# developer seats carry no autoupdate label on purpose, because an agent in one
# runs jobs that take hours and a 03:00 restart destroys the work. A release
# lands there when a seat is restarted deliberately, between jobs.
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
# Usage: check_deploy_drift.sh [grace_hours] [deployer_grace_hours]

set -uo pipefail

GRACE_HOURS=${1:-30}
DEPLOYER_GRACE_HOURS=${2:-24}
SOCK=${PODMAN_SOCK:-/run/podman/podman.sock}
FOLLOW_STATUS=${FOLLOW_STATUS:-/var/lib/deployer/follower/release-follow.status}
# Three hourly passes, the same threshold check_release_follow.sh warns at.
FOLLOW_STALE=${FOLLOW_STALE:-10800}

OK=0; WARNING=1; UNKNOWN=3

if ! [[ "$GRACE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "DEPLOY DRIFT UNKNOWN - grace_hours must be a whole number"
    exit $UNKNOWN
fi
if ! [[ "$DEPLOYER_GRACE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "DEPLOY DRIFT UNKNOWN - deployer_grace_hours must be a whole number"
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
unmanaged=""; stale=""; contested=""; unknown=""; clean=0; pinned=0; deployer=0

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
        DEPLOYER)  deployer=$((deployer + 1)) ;;
        CONTESTED) contested="$contested $name" ;;
        UNKNOWN)   unknown="$unknown $name" ;;
    esac
# `-t '='`, not `-t=`: GNU sort reads the fused form as the separator '=',
# and uutils sort -- which is what coreutils is on ubuntu-26.04 runners since
# the 20261101 image -- reads it as an empty separator and refuses with
# "separator must be exactly one character long: ''". Thirteen tests failed
# on that alone, in a build whose diff was somewhere else entirely (RT#1558).
done < <(grep '^DDRIFT item=' <<< "$CL_RAW" | sort -t '=' -k5)

# ---- deployer-registry services, from the release follower's status file ----

undeployed=""; judged=0; follow_note=""; follow_age=0
dgrace=$((DEPLOYER_GRACE_HOURS * 3600))
follow_raw=""
[ -f "$FOLLOW_STATUS" ] && [ -r "$FOLLOW_STATUS" ] && follow_raw=$(cat "$FOLLOW_STATUS" 2>/dev/null)
follow_head=$(grep -m1 '^FOLLOWER generated=' <<< "$follow_raw")
follow_gen=$(cl_field generated "$follow_head")
if [ -z "$follow_raw" ]; then
    follow_note="no follower status"
elif ! grep -qx 'FOLLOWER end=1' <<< "$follow_raw"; then
    follow_note="follower status truncated"
elif ! [[ "$follow_gen" =~ ^[0-9]+$ ]]; then
    follow_note="follower status has no generated time"
elif follow_age=$(( now - follow_gen )); [ "$follow_age" -ge "$FOLLOW_STALE" ]; then
    follow_note="follower status $(( follow_age / 3600 ))h old"
elif ! grep -q '^FOLLOWER service .* since=' <<< "$follow_raw" && grep -q '^FOLLOWER service ' <<< "$follow_raw"; then
    # 0.8.0 wrote no since=, so a behind service there has no age to judge.
    follow_note="follower status predates since= (deployer < 0.9.0)"
else
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        svc=$(cl_field name "$line"); since=$(cl_field since "$line")
        if [ "$(cl_field result "$line")" = error ]; then
            unknown="$unknown ${svc}(follower)"
            continue
        fi
        judged=$((judged + 1))
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        if [ $(( now - since )) -ge "$dgrace" ]; then
            undeployed="$undeployed ${svc}($(( (now - since) / 3600 ))h)"
        fi
    done < <(grep '^FOLLOWER service ' <<< "$follow_raw")
fi
[ "$follow_age" -lt 0 ] && follow_age=0

n_unmanaged=$(printf '%s' "$unmanaged" | wc -w)
n_stale=$(printf '%s' "$stale" | wc -w)
n_contested=$(printf '%s' "$contested" | wc -w)
n_undeployed=$(printf '%s' "$undeployed" | wc -w)
n_unknown=$(printf '%s' "$unknown" | wc -w)
drift=$((n_unmanaged + n_stale + n_contested + n_undeployed))
# Containers and deployer services are counted in one total: both are things
# this check compared, and the honesty thresholds below are over all of them.
total=$((n_unmanaged + n_stale + n_contested + n_unknown + clean + judged))

perf="unmanaged=${n_unmanaged};;;0 stale=${n_stale};;;0 contested=${n_contested};;;0 undeployed=${n_undeployed};;;0 clean=${clean};;;0 unknown=${n_unknown};;;0 pinned=${pinned};;;0 deployer=${deployer};;;0 collected_age=${CL_AGE}s;;${STALE} follower_age=${follow_age}s;;${FOLLOW_STALE}"

detail=""
[ -n "$unmanaged" ] && detail="${detail}unmanaged (no autoupdate label):${unmanaged}. "
[ -n "$stale" ] && detail="${detail}stale (auto-update not applying):${stale}. "
[ -n "$contested" ] && detail="${detail}contested (deployer marker AND autoupdate=registry):${contested}. "
[ -n "$undeployed" ] && detail="${detail}undeployed (deployer service behind :latest over ${DEPLOYER_GRACE_HOURS}h):${undeployed}. "
[ -n "$unknown" ] && detail="${detail}unreadable:${unknown}. "
[ -n "$CL_KICKED" ] && detail="${detail}${CL_KICKED# }. "

if [ "$n_unknown" -gt 0 ] && [ "$drift" -eq 0 ]; then
    echo "DEPLOY DRIFT UNKNOWN - ${n_unknown}/${total} could not be checked. ${detail}| $perf"
    exit $UNKNOWN
fi

if [ "$n_unknown" -gt $((total / 2)) ]; then
    echo "DEPLOY DRIFT UNKNOWN - ${n_unknown}/${total} could not be checked, too many to trust the rest. ${detail}| $perf"
    exit $UNKNOWN
fi

# Said in the headline and not only in the perfdata: these are the services
# that have LEFT auto-update for the deploy robot, and that count going back to
# zero on its own would be the marker having been dropped from a unit -- the
# one way this could quietly stop being true.
managed=""
[ "$deployer" -gt 0 ] && managed=", ${deployer} deployed by ticket"
# Said either way, so a reader can tell "no deployer service is behind" from
# "deployer services were not looked at".
if [ -n "$follow_note" ]; then
    managed="${managed} (deployer services not compared: ${follow_note})"
else
    managed="${managed} (${judged} deployer services compared with :latest)"
fi

if [ "$drift" -eq 0 ]; then
    echo "DEPLOY DRIFT OK - ${clean}/$((total - judged)) containers run the image their tag points at${managed} | $perf"
    exit $OK
fi

blind=""
[ "$n_unknown" -gt 0 ] && blind=", ${n_unknown} UNCHECKED"
echo "DEPLOY DRIFT WARNING - ${drift}/${total} drifted: ${n_unmanaged} unmanaged, ${n_stale} stale, ${n_contested} contested, ${n_undeployed} undeployed${blind}. ${detail}| $perf"
exit $WARNING
