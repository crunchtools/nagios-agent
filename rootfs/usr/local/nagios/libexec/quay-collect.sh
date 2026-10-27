#!/bin/bash
# quay-collect.sh — Quay tag ages off the NRPE hot path (7.1.0)
# Usage: quay-collect.sh [<org/repo> <tag>]...
#
# THE PROBLEM. check_quay_staleness.sh asked the Quay API live on every run,
# with no timeout, three images every three minutes. A slow Quay answer turned
# into UNKNOWN or check_nrpe's "CRITICAL - Socket timeout" (19 such alerts in
# the Nagios log), which says nothing about how old an image is.
#
# THE SPLIT. This script reads every watched tag in parallel, PROBE_T (20s) a
# call with one retry inside BUDGET (60s), and writes quay.status. The plugin
# only reads that file, and starts this script through
# `podman_exec.sh --detach` in nagios-agent-ctr.crunchtools.com when the file
# is older than its REFRESH (2m, under the 3m check_interval). Nagios is the
# clock; a flock stops overlapping runs. Quay's tag API is anonymous for public
# repos, so there is no credential here.
#
# WHAT IT WATCHES. Every `check_quay_staleness.sh <repo> <days> <tag>` command
# in the NRPE config the plugins run under (NRPE_CFG), so adding a check adds
# its image, plus any <repo> <tag> pairs given as arguments, which is how a
# plugin run by hand for an unlisted image gets it collected.
#
# WHAT IT WRITES, $STATE_DIR/quay.status, replaced atomically:
#   QUAY generated=<epoch> elapsed=<s>
#   QUAY item=<repo>:<tag> seen=<epoch> result=ok modified=<epoch>
#   QUAY item=<repo>:<tag> seen=<epoch> result=notag
#   QUAY item=<repo>:<tag> seen=<epoch> result=badtime|error msg=<text>
#   QUAY end=1
#
# seen is when Quay last answered for that tag. A call that fails keeps the
# previous answer, seen and all; the plugin turns one older than its STALE into
# UNKNOWN. Facts only: the age threshold is the plugin's argument.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

NRPE_CFG=${NRPE_CFG:-/etc/nagios/nrpe.cfg}
QUAY_API=${QUAY_API:-https://quay.io/api/v1}
BUDGET=${BUDGET:-60}
PROBE_T=${PROBE_T:-20}
STATUS="$STATE_DIR/quay.status"

cl_lock quay

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/res"

valid() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$ && $2 =~ ^[A-Za-z0-9._-]+$ ]]; }

{
    [ -r "$NRPE_CFG" ] && grep -oE 'check_quay_staleness\.sh +[^ ]+ +[0-9]+ +[^ ]+' "$NRPE_CFG" \
        | awk '{ print $2, $4 }'
    while [ $# -ge 2 ]; do echo "$1 $2"; shift 2; done
} | sort -u > "$TMP/items"

probe() { # <repo> <tag>: one QUAY line to $TMP/res/<n>
    local repo=$1 tag=$2 res=$3 body="$TMP/body.${3##*/}" rc=1 tries=0 left t modified epoch
    local head="QUAY item=$repo:$tag"
    while [ "$tries" -lt 2 ]; do
        left=$(( START + BUDGET - $(date +%s) ))
        [ "$left" -lt 2 ] && { rc=28; break; }
        t=$(( left < PROBE_T ? left : PROBE_T ))
        if curl -sS --connect-timeout 10 --max-time "$t" \
            "$QUAY_API/repository/${repo}/tag/?limit=1&specificTag=${tag}&onlyActiveTags=true" \
            > "$body" 2>"$body.err"; then
            grep -q '"tags"' "$body" && { rc=0; break; }
            rc=unparseable
        else
            rc=$?
        fi
        tries=$((tries + 1))
    done
    if [ "$rc" != 0 ]; then
        echo "$head seen=$(date +%s) result=error msg=$(cl_clean "curl_exit_$rc:$(head -1 "$body.err" 2>/dev/null)")" > "$res"; return
    fi
    modified=$(grep -oP '"last_modified":\s*"\K[^"]+' "$body" | head -1)
    if [ -z "$modified" ]; then
        echo "$head seen=$(date +%s) result=notag" > "$res"; return
    fi
    if ! epoch=$(date -d "$modified" +%s 2>/dev/null); then
        echo "$head seen=$(date +%s) result=badtime msg=$(cl_clean "$modified")" > "$res"; return
    fi
    echo "$head seen=$(date +%s) result=ok modified=$epoch" > "$res"
}

n=0
while read -r repo tag; do
    valid "$repo" "$tag" || continue
    n=$((n + 1))
    probe "$repo" "$tag" "$TMP/res/$n" &
done < "$TMP/items"
wait

{
    echo "QUAY generated=$START elapsed=$(( $(date +%s) - START ))"
    for f in "$TMP"/res/*; do
        [ -e "$f" ] || continue
        line=$(cat "$f")
        if [[ $line == *" result=error "* ]]; then
            item=$(cl_field item "$line")
            prev=$(cl_previous "$STATUS" "^QUAY item=${item//./\\.} seen=[0-9]+ result=(ok|notag)( |$)" | head -1)
            [ -n "$prev" ] && line=$prev
        fi
        echo "$line"
    done
    echo "QUAY end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
