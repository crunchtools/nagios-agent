#!/bin/bash
# registry-drift-collect.sh — registry drift reads off the NRPE hot path (7.1.0)
#
# THE PROBLEM. check_registry_drift.sh made ~170 network calls against GitHub,
# Quay and GHCR on every run, inside check_nrpe's 45s ceiling. Parallel workers
# got it to ~10s, but a slow registry still turned into "CRITICAL - Socket
# timeout" (31 CRITICALs in the Nagios log), which says nothing about drift.
#
# THE SPLIT. This script does every read (the functions below moved here
# unchanged from the plugin, see its header for what they compare and why),
# 8 images at a time, NET_TIMEOUT (15s) a call, inside BUDGET (120s), and
# writes registry-drift.status. check_registry_drift.sh judges that file, with
# the 4h grace computed when it judges, and starts this script through
# `podman_exec.sh --detach` in nagios-agent-ctr.crunchtools.com when the file
# is older than its REFRESH (30m, under the 60m check_interval). Nagios is the
# clock; a flock stops overlapping runs.
#
# WHAT IT WRITES, $STATE_DIR/registry-drift.status, replaced atomically:
#   RDRIFT generated=<epoch> elapsed=<s>
#   RDRIFT generated=<epoch> error=conf_unreadable
#   RDRIFT item=<image> seen=<epoch> kind=CLEAN|SKIPPED
#   RDRIFT item=<image> seen=<epoch> kind=UNTAGGED value=<repo>
#   RDRIFT item=<image> seen=<epoch> kind=MISSING value=<image>:<tag>[<registries>] since=<epoch|0>
#   RDRIFT item=<image> seen=<epoch> kind=UNKNOWN value=<image>(git|quay|ghcr|budget)
#   RDRIFT end=1
#
# An image that could not be read this run (UNKNOWN) keeps its previous
# answer, seen and all; the plugin counts one older than its STALE as
# unreadable, which keeps the honesty rule: no OK for a comparison that did
# not happen recently. since is the release date the grace is measured from.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

CONF=${REGISTRY_DRIFT_CONF:-/etc/nagios/registry-images.conf}
QUAY_API=${QUAY_API:-https://quay.io/api/v1}
GHCR=${GHCR:-https://ghcr.io}
ORG=${REGISTRY_DRIFT_ORG:-crunchtools}
GIT_HOST=${REGISTRY_DRIFT_GIT_HOST:-https://github.com}
NET_TIMEOUT=${REGISTRY_DRIFT_TIMEOUT:-15}
SOCK=${REGISTRY_DRIFT_SOCK:-/run/podman/podman.sock}

# Bare `git ls-remote` against anything it cannot read BLOCKS on a credential
# prompt rather than failing. Unset, a run hangs until its budget runs out and
# every image goes UNKNOWN with no detail. Belt and braces: refuse the prompt,
# and bound every call with timeout regardless.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

BUDGET=${BUDGET:-120}
STATUS="$STATE_DIR/registry-drift.status"

cl_lock registry-drift

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

if [ ! -r "$CONF" ]; then
    printf 'RDRIFT generated=%s error=conf_unreadable\nRDRIFT end=1\n' "$START" > "$TMP/status"
    cl_publish "$TMP/status" "$STATUS"
    exit 0
fi

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

# Asks for tag <want> by name, then v<want> only if that found nothing. A plain
# listing is newest first and capped at 100, so a repo that tags every commit
# (rotv) pushed its release tag off the page and read as MISSING while Quay
# had it (2026-10-29).
quay_body() {
    local t body
    for t in "$2" "v$2"; do
        body=$(curl -sf --max-time "$NET_TIMEOUT" \
            "${QUAY_API}/repository/${ORG}/$1/tag/?onlyActiveTags=true&specificTag=${t}") || return 1
        printf '%s\n' "$body"
        [ -n "$(quay_names "$body")" ] && return 0
    done
    return 0
}

quay_names() { printf '%s' "$1" | grep -oP '"name":\s*"\K[^"]+'; }

# start_ts of tag <want> (or v<want>) in a Quay tag listing. Tag objects can
# nest (child_manifests_presence), so split the listing at each tag's "name"
# key rather than at braces: each piece is then one tag's fields.
quay_start() {
    printf '%s' "$1" | sed 's/{"name"/\n{"name"/g' \
        | grep -E "^\{\"name\":\s*\"v?${2//./\\.}\"" \
        | grep -oP '"start_ts":\s*\K[0-9]+' | head -1
}

# Created epoch of a local image tagged <img>:<tag> on either registry, from
# the image list fetched once into $LOCAL_IMAGES. sqlite3 reads the JSON (the
# image has no jq); <img> is checked against a strict pattern before it is
# spliced into the query, and <tag> is semver digits by construction.
local_created() {
    local img=$1 tag=$2 refs="" r
    [ -s "${LOCAL_IMAGES:-}" ] || return 0
    command -v sqlite3 >/dev/null || return 0
    [[ $img =~ ^[a-z0-9._-]+$ && $tag =~ ^[0-9.]+$ ]] || return 0
    for r in "quay.io/${ORG}/${img}" "ghcr.io/${ORG}/${img}"; do
        refs="${refs:+$refs,}'$r:$tag','$r:v$tag'"
    done
    sqlite3 :memory: "SELECT coalesce(max(json_extract(i.value,'\$.Created')),'')
        FROM json_each(CAST(readfile('$LOCAL_IMAGES') AS TEXT)) i,
             json_each(i.value,'\$.RepoTags') t
        WHERE t.value IN ($refs)" 2>/dev/null | grep -E '^[0-9]+$'
}

ghcr_tags() {
    local img=$1 token body
    # Anonymous pull token. Every image checked here is public; the one private
    # package in the org belongs to the repo this plugin deliberately skips.
    token=$(curl -sf --max-time "$NET_TIMEOUT" \
        "${GHCR}/token?scope=repository:${ORG}/${img}:pull&service=ghcr.io" \
        | grep -oP '"token":\s*"\K[^"]+') || return 1
    [ -n "$token" ] || return 1
    # ghcr pages tags/list at 100 by default; ask for everything in one page.
    body=$(curl -sf --max-time "$NET_TIMEOUT" -H "Authorization: Bearer ${token}" \
        "${GHCR}/v2/${ORG}/${img}/tags/list?n=10000") || return 1
    printf '%s' "$body" | grep -oP '"tags":\s*\[\K[^]]*' | tr ',' '\n' | tr -d ' "'
    return 0
}

# One image in, one verdict line out, led by the image name. Everything network-bound lives in here so
# the images can be checked concurrently; the verdicts are tallied afterwards by
# a single reader, which keeps the counting logic sequential and easy to follow.
check_one() {
    local repo=$1 img=$2 flag=${3:-} tag gaps qb qt gt since

    # A fork's git tags are upstream's releases, not versions of the image we
    # publish, so there is nothing here to compare. Quay staleness covers them.
    if [ "$flag" = "fork" ]; then
        printf '%s SKIPPED\n' "$img"
        return
    fi

    if ! tag=$(newest_tag "$repo"); then
        printf '%s UNKNOWN %s(git)\n' "$img" "$img"
        return
    fi

    if [ -z "$tag" ]; then
        printf '%s UNTAGGED %s\n' "$img" "$repo"
        return
    fi

    gaps=""

    if qb=$(quay_body "$img" "$tag"); then
        qt=$(quay_names "$qb")
        tag_present "$qt" "$tag" || gaps="quay"
    else
        printf '%s UNKNOWN %s(quay)\n' "$img" "$img"
        return
    fi

    if gt=$(ghcr_tags "$img"); then
        tag_present "$gt" "$tag" || gaps="${gaps:+$gaps+}ghcr"
    else
        printf '%s UNKNOWN %s(ghcr)\n' "$img" "$img"
        return
    fi

    if [ -n "$gaps" ]; then
        since=""
        [ "$gaps" = ghcr ] && since=$(quay_start "$qb" "$tag")
        [ -n "$since" ] || since=$(local_created "$img" "$tag")
        printf '%s MISSING %s:%s[%s] %s\n' "$img" "$img" "$tag" "$gaps" "${since:-0}"
    else
        printf '%s CLEAN\n' "$img"
    fi
}
export -f check_one newest_tag quay_body quay_names quay_start local_created ghcr_tags tag_present

# One read of the local image list for local_created(). Failure just means no
# local dates, so every missing image without a Quay date counts as aged.
LOCAL_IMAGES="$TMP/local-images.json"
if [ -S "$SOCK" ]; then
    curl -sf --max-time "$NET_TIMEOUT" --unix-socket "$SOCK" \
        "http://localhost/v5.0.0/libpod/images/json" > "$LOCAL_IMAGES" 2>/dev/null || : > "$LOCAL_IMAGES"
fi
export QUAY_API GHCR ORG GIT_HOST NET_TIMEOUT LOCAL_IMAGES

# One line per image, deduplicated so a doubled conf line is not counted twice.
grep -vE '^[[:space:]]*(#|$)' "$CONF" | awk '!seen[$1" "$2]++' > "$TMP/images"

# Workers append one short line each to a file; small O_APPEND writes do not
# interleave. When BUDGET runs out timeout stops xargs and its workers, and an
# image with no line is then UNKNOWN (budget) below. A call already inside its
# own `timeout NET_TIMEOUT` sits in that timeout's process group and can
# outlive this run by up to NET_TIMEOUT, so the workers get no copy of the lock
# (9>&-): a straggler must not keep the next run out.
JOBS=${REGISTRY_DRIFT_JOBS:-8}
: > "$TMP/results"
timeout "$BUDGET" xargs -P "$JOBS" -L1 bash -c 'check_one "$@"' _ < "$TMP/images" >> "$TMP/results" 2>/dev/null 9>&-

# Index the workers' lines by image once: "<kind> <value> <since>".
declare -A answer=()
while read -r img rest; do
    [[ $img =~ ^[A-Za-z0-9._-]+$ ]] || continue   # same rule as the conf loop below
    [ -z "${answer[$img]:-}" ] && answer[$img]=$rest
done < "$TMP/results"

{
    echo "RDRIFT generated=$START elapsed=$(( $(date +%s) - START ))"
    while read -r _ img _; do
        [[ $img =~ ^[A-Za-z0-9._-]+$ ]] || continue
        read -r kind value since <<< "${answer[$img]:-}"
        [ -n "${kind:-}" ] || { kind=UNKNOWN; value="$img(budget)"; since=""; }
        line="RDRIFT item=$img seen=$START kind=$kind${value:+ value=$value}${since:+ since=$since}"
        if [ "$kind" = UNKNOWN ]; then
            # Could not look this time: keep the last real answer if there is one.
            prev=$(cl_previous "$STATUS" "^RDRIFT item=${img//./\\.} seen=[0-9]+ kind=(CLEAN|SKIPPED|UNTAGGED|MISSING)( |$)" | head -1)
            [ -n "$prev" ] && line=$prev
        fi
        echo "$line"
        kind="" value="" since=""
    done < "$TMP/images"
    echo "RDRIFT end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
