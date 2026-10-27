#!/bin/bash
# check_registry_drift.sh — does each registry actually carry the version the
# repo says is current? (RT #1480 follow-on)
#
# WHY THIS EXISTS. RT #1480 put all 36 container workflows on dual-push to Quay
# and GHCR. Nothing watched whether that kept working. The only registry
# monitoring was check_quay_staleness.sh on three images, and it asks "is the
# tag old?" -- never "is it the right code?" -- and never looks at GHCR at all.
#
# That gap has teeth because build-and-push-ghcr is gated on
# `needs: build-and-push-quay`. If the GHCR job starts failing -- expired
# permissions, a package visibility change, a buildx regression -- Quay keeps
# publishing, Quay staleness stays green, and the mirror rots silently until
# the day someone needs it. rt and acquacotta are in exactly that state today:
# their versions exist on Quay and were never mirrored to GHCR.
#
# WHAT IT COMPARES. The newest semver git tag, read straight from GitHub with
# `git ls-remote`. No Releases API and no token -- git-core is already in this
# image, public repos need no credentials, and there is no API rate limit to
# exhaust or secret to rotate. Two findings fall out:
#
#   untagged  the repo has no semver tag at all. Constitution V mandates SemVer
#             2.0.0, so a container repo that never tags has no releasable
#             version -- that is a bug, not an exemption.
#   missing   a tag exists but a registry has no image carrying it. Either the
#             workflow lacks type=semver / a tags: ["v*"] trigger, or a push
#             failed.
#
# The two need different fixes -- cut a tag, versus fix the workflow -- so they
# are counted and listed separately rather than blended into one number.
#
# WARNING, not CRITICAL, on purpose: drift is a process defect, not an outage,
# and hermes pages on CRITICAL only (contacts.cfg, service_notification_options
# c). This should nag from the dashboard, not wake anyone.
#
# GRACE (7.0.0). A release is missing from a registry for a while by design:
# the tag lands on GitHub, CI builds, Quay gets the image, then GHCR. Warning
# in that window was noise, so a "missing" image is dated and stays OK for
# REGISTRY_DRIFT_WARN seconds (4h). The date comes from what can be read
# without a token or state: Quay's start_ts for the tag when Quay has it (the
# gap is GHCR, which follows Quay), else the Created time of a local image
# carrying that tag (podman socket), else none, which counts as aged and warns
# at once as before. "untagged" has no release to date and always warns.
#
# HONESTY RULE (RT #1481, RT #1488). Never report OK for a comparison that did
# not happen. Every git or registry call that fails is counted as unknown and
# named in the output. A check that reports OK when it did not run is worse
# than no check, because it occupies the slot where a working one would go.

# COLLECTOR (7.1.0). Every read above now happens in registry-drift-collect.sh,
# which writes registry-drift.status; this plugin only judges that file, so a
# slow registry can no longer time the check out. When the file is missing or
# older than REFRESH (30m, under the 60m check_interval) the collector is
# started detached through `podman_exec.sh --detach` in
# nagios-agent-ctr.crunchtools.com and the previous run's file is judged. An
# image the collector last read more than STALE (3h) ago counts as unreadable,
# and the whole check is UNKNOWN "collector stale" when the file is missing or
# older than STALE. The grace is measured here, at judging time, from the
# release date the collector recorded, so it stays stateless.

set -uo pipefail

CONF=${REGISTRY_DRIFT_CONF:-/etc/nagios/registry-images.conf}
WARN=${REGISTRY_DRIFT_WARN:-14400}

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "REGISTRY DRIFT UNKNOWN - cannot load collector-lib.sh"; exit $UNKNOWN; }
STATUS=${STATUS:-$STATE_DIR/registry-drift.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/registry-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-1800}
STALE=${STALE:-10800}

cl_open RDRIFT "REGISTRY DRIFT"
if grep -q '^RDRIFT generated=[0-9]* error=conf_unreadable' <<< "$CL_RAW"; then
    echo "REGISTRY DRIFT UNKNOWN - cannot read image list at ${CONF}"
    exit $UNKNOWN
fi

# One "kind value since" line per image, as the collector's workers wrote it.
# An answer older than STALE is not judged: it counts as unreadable.
results=$(
    while IFS= read -r line; do
        img=$(cl_field item "$line"); seen=$(cl_field seen "$line")
        if [ $(( $(date +%s) - ${seen:-0} )) -ge "$STALE" ]; then
            echo "UNKNOWN ${img}(stale)"
        else
            echo "$(cl_field kind "$line") $(cl_field value "$line") $(cl_field since "$line")"
        fi
    done < <(grep '^RDRIFT item=' <<< "$CL_RAW") | sort
)
if [ -z "$results" ]; then
    echo "REGISTRY DRIFT UNKNOWN - collector stale: $STATUS holds no images"
    exit $UNKNOWN
fi

untagged=""; missing=""; unknown=""; clean=0; total=0; skipped=0
seen_untagged=""; grace=""; now=$(date +%s); oldest_age=-1

dur() { if [ "$1" -ge 3600 ]; then echo "$(( $1 / 3600 ))h"; else echo "$(( $1 / 60 ))m"; fi; }

while read -r kind value since; do
    case "$kind" in
        SKIPPED) skipped=$((skipped + 1)) ;;
        CLEAN)   clean=$((clean + 1));    total=$((total + 1)) ;;
        UNKNOWN) unknown="$unknown $value"; total=$((total + 1)) ;;
        MISSING)
            total=$((total + 1))
            age=$WARN
            [ "${since:-0}" -gt 0 ] 2>/dev/null && age=$(( now - since ))
            [ "$age" -lt 0 ] && age=0
            if [ "$age" -lt "$WARN" ]; then
                grace="$grace $value"
                [ "$age" -gt "$oldest_age" ] && oldest_age=$age
            else
                missing="$missing $value"
            fi ;;
        UNTAGGED)
            total=$((total + 1))
            # Count the repo once even when it publishes several images; the fix
            # is one tag, not one per image.
            case " $seen_untagged " in
                *" $value "*) : ;;
                *) untagged="$untagged $value"; seen_untagged="$seen_untagged $value" ;;
            esac
            ;;
    esac
done <<< "$results"

n_untagged=$(printf '%s' "$untagged" | wc -w)
n_missing=$(printf '%s' "$missing" | wc -w)
n_unknown=$(printf '%s' "$unknown" | wc -w)
n_grace=$(printf '%s' "$grace" | wc -w)
drift=$((n_untagged + n_missing))

perf="untagged=${n_untagged};;;0 missing=${n_missing};;;0 clean=${clean};;;0 unknown=${n_unknown};;;0 skipped=${skipped};;;0 in_grace=${n_grace};;;0 collected_age=${CL_AGE}s;;${STALE}"

detail=""
[ -n "$untagged" ] && detail="${detail}untagged:${untagged}. "
[ -n "$missing" ] && detail="${detail}missing:${missing}. "
[ -n "$unknown" ] && detail="${detail}unreadable:${unknown}. "
[ -n "$grace" ] && detail="${detail}in grace:${grace}. "
[ -n "$CL_KICKED" ] && detail="${detail}${CL_KICKED# }. "

# How unreadable images are handled, since the honest answer is not simply
# "always UNKNOWN". The collector makes ~170 network calls per run against three
# external services, so the occasional transient failure is certain. Flipping the whole
# check to UNKNOWN on one flaky call would bury real drift behind noise and
# train everyone to ignore it -- the same way a check that never runs occupies
# the slot a working one would fill.
#
# So: UNKNOWN when we genuinely cannot see -- nothing drifted but something was
# unreadable, or more than half the fleet was unreadable. Otherwise report the
# drift we did find, with the unreadable count in the HEADLINE rather than
# buried in the detail, so nobody reads a WARNING as a complete picture.
blind_limit=$((total / 2))

if [ "$n_unknown" -gt 0 ] && [ "$drift" -eq 0 ]; then
    echo "REGISTRY DRIFT UNKNOWN - ${n_unknown}/${total} images could not be checked. ${detail}| $perf"
    exit $UNKNOWN
fi

if [ "$n_unknown" -gt "$blind_limit" ]; then
    echo "REGISTRY DRIFT UNKNOWN - ${n_unknown}/${total} images could not be checked, too many to trust the rest. ${detail}| $perf"
    exit $UNKNOWN
fi

if [ "$drift" -eq 0 ] && [ "$n_grace" -gt 0 ]; then
    echo "REGISTRY DRIFT OK - drift $(dur "$oldest_age"), within grace (warn after $(dur "$WARN")): ${n_grace}/${total} images not yet on every registry. ${detail}| $perf"
    exit $OK
fi

if [ "$drift" -eq 0 ]; then
    echo "REGISTRY DRIFT OK - ${clean}/${total} images carry their newest semver tag on every expected registry | $perf"
    exit $OK
fi

blind=""
[ "$n_unknown" -gt 0 ] && blind=", ${n_unknown} UNCHECKED"
echo "REGISTRY DRIFT WARNING - ${drift}/${total} images drifted: ${n_untagged} untagged, ${n_missing} missing from a registry${blind}. ${detail}| $perf"
exit $WARNING
