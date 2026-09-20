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
# HONESTY RULE (RT #1481, RT #1488). Never report OK for a comparison that did
# not happen. Every git or registry call that fails is counted as unknown and
# named in the output. A check that reports OK when it did not run is worse
# than no check, because it occupies the slot where a working one would go.

set -uo pipefail

CONF=${REGISTRY_DRIFT_CONF:-/etc/nagios/registry-images.conf}
QUAY_API=${QUAY_API:-https://quay.io/api/v1}
GHCR=${GHCR:-https://ghcr.io}
ORG=${REGISTRY_DRIFT_ORG:-crunchtools}
GIT_HOST=${REGISTRY_DRIFT_GIT_HOST:-https://github.com}
NET_TIMEOUT=${REGISTRY_DRIFT_TIMEOUT:-15}

# Bare `git ls-remote` against anything it cannot read BLOCKS on a credential
# prompt rather than failing. Unset, this plugin hangs until NRPE gives up and
# the service goes UNKNOWN with no detail. Belt and braces: refuse the prompt,
# and bound every call with timeout regardless.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

[ -r "$CONF" ] || {
    echo "REGISTRY DRIFT UNKNOWN - cannot read image list at ${CONF}"
    exit $UNKNOWN
}

# Newest semver tag for a repo. Prints nothing on success-with-no-tags, and
# returns non-zero only when the remote could not be read -- the caller needs
# to tell "no tags" (a finding) from "could not look" (unknown).
newest_tag() {
    local repo=$1 out
    out=$(timeout "$NET_TIMEOUT" git ls-remote --tags --refs "${GIT_HOST}/${ORG}/${repo}" 2>/dev/null) || return 1
    # --refs drops the ^{} peeled entries; sort -V orders semver properly.
    printf '%s\n' "$out" \
        | awk '{print $2}' \
        | sed 's#refs/tags/##' \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' \
        | sort -V \
        | tail -1
    return 0
}

# Quay and GHCR are inconsistent about the v prefix: a git tag of v0.7.0 is
# published as 0.7.0 on Quay, and some images carry both. Accept either.
tag_present() {
    local tags=$1 want=$2
    printf '%s\n' "$tags" | grep -qxF "$want" && return 0
    printf '%s\n' "$tags" | grep -qxF "v$want"
}

quay_tags() {
    local img=$1 body
    body=$(curl -sf --max-time "$NET_TIMEOUT" \
        "${QUAY_API}/repository/${ORG}/${img}/tag/?onlyActiveTags=true&limit=100") || return 1
    printf '%s' "$body" | grep -oP '"name":\s*"\K[^"]+'
    return 0
}

ghcr_tags() {
    local img=$1 token body
    # Anonymous pull token. Every image checked here is public; the one private
    # package in the org belongs to the repo this plugin deliberately skips.
    token=$(curl -sf --max-time "$NET_TIMEOUT" \
        "${GHCR}/token?scope=repository:${ORG}/${img}:pull&service=ghcr.io" \
        | grep -oP '"token":\s*"\K[^"]+') || return 1
    [ -n "$token" ] || return 1
    body=$(curl -sf --max-time "$NET_TIMEOUT" -H "Authorization: Bearer ${token}" \
        "${GHCR}/v2/${ORG}/${img}/tags/list") || return 1
    printf '%s' "$body" | grep -oP '"tags":\s*\[\K[^]]*' | tr ',' '\n' | tr -d ' "'
    return 0
}

# One image in, one verdict line out. Everything network-bound lives in here so
# the images can be checked concurrently; the verdicts are tallied afterwards by
# a single reader, which keeps the counting logic sequential and easy to follow.
check_one() {
    local repo=$1 img=$2 flag=${3:-} tag gaps qt gt

    # A fork's git tags are upstream's releases, not versions of the image we
    # publish, so there is nothing here to compare. Quay staleness covers them.
    if [ "$flag" = "fork" ]; then
        printf 'SKIPPED\n'
        return
    fi

    if ! tag=$(newest_tag "$repo"); then
        printf 'UNKNOWN %s(git)\n' "$img"
        return
    fi

    if [ -z "$tag" ]; then
        printf 'UNTAGGED %s\n' "$repo"
        return
    fi

    gaps=""

    if qt=$(quay_tags "$img"); then
        tag_present "$qt" "$tag" || gaps="quay"
    else
        printf 'UNKNOWN %s(quay)\n' "$img"
        return
    fi

    if gt=$(ghcr_tags "$img"); then
        tag_present "$gt" "$tag" || gaps="${gaps:+$gaps+}ghcr"
    else
        printf 'UNKNOWN %s(ghcr)\n' "$img"
        return
    fi

    if [ -n "$gaps" ]; then
        printf 'MISSING %s:%s[%s]\n' "$img" "$tag" "$gaps"
    else
        printf 'CLEAN\n'
    fi
}
export -f check_one newest_tag quay_tags ghcr_tags tag_present
export QUAY_API GHCR ORG GIT_HOST NET_TIMEOUT

# Run the images concurrently. Serially this made ~170 network calls back to
# back and took ~39s against check_nrpe's 45s ceiling -- 86% of the budget, so
# any registry latency tipped it to CRITICAL "Socket timeout". It did exactly
# that three times during one deploy on 2026-09-20, while the underlying answer
# was a clean 56/56. A monitoring check that cries wolf during deploys, which is
# precisely when someone is watching, trains everyone to ignore it.
#
# Each worker prints one short line and only at the end, and writes under
# PIPE_BUF are atomic on a pipe, so the verdicts cannot interleave.
#
# Sorted on the way out: workers finish in whatever order the network allows,
# and without this the names in the detail list shuffle between runs of an
# otherwise unchanged check.
JOBS=${REGISTRY_DRIFT_JOBS:-8}
results=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | xargs -P "$JOBS" -L1 bash -c 'check_one "$@"' _ \
    | sort)

untagged=""; missing=""; unknown=""; clean=0; total=0; skipped=0
seen_untagged=""

while read -r kind value; do
    case "$kind" in
        SKIPPED) skipped=$((skipped + 1)) ;;
        CLEAN)   clean=$((clean + 1));    total=$((total + 1)) ;;
        UNKNOWN) unknown="$unknown $value"; total=$((total + 1)) ;;
        MISSING) missing="$missing $value"; total=$((total + 1)) ;;
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
drift=$((n_untagged + n_missing))

perf="untagged=${n_untagged};;;0 missing=${n_missing};;;0 clean=${clean};;;0 unknown=${n_unknown};;;0 skipped=${skipped};;;0"

detail=""
[ -n "$untagged" ] && detail="${detail}untagged:${untagged}. "
[ -n "$missing" ] && detail="${detail}missing:${missing}. "
[ -n "$unknown" ] && detail="${detail}unreadable:${unknown}. "

# How unreadable images are handled, since the honest answer is not simply
# "always UNKNOWN". This makes ~56 network calls per run against three external
# services, so the occasional transient failure is certain. Flipping the whole
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

if [ "$drift" -eq 0 ]; then
    echo "REGISTRY DRIFT OK - ${clean}/${total} images carry their newest semver tag on every expected registry | $perf"
    exit $OK
fi

blind=""
[ "$n_unknown" -gt 0 ] && blind=", ${n_unknown} UNCHECKED"
echo "REGISTRY DRIFT WARNING - ${drift}/${total} images drifted: ${n_untagged} untagged, ${n_missing} missing from a registry${blind}. ${detail}| $perf"
exit $WARNING
