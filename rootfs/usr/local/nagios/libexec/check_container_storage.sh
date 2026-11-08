#!/bin/bash
# check_container_storage.sh — watch the nested podman image stores (pure bash)
#
# Usage: check_container_storage.sh <warn-GB> <crit-GB> [service ...]
#
# WHAT THIS IS FOR. developer1-3 and gha-runner-cached each run their own podman
# inside the service container, with its own storage under
# /srv/<svc>/data/containers. Nothing used to remove anything from them: on
# 2026-11-08 they held 1,190,137 files and 49.5 GiB, mostly the same image over
# and over, because podman-auto-update pulls python-sdlc most days. That mass is
# what stopped the weekly pbs Servers sync converging -- it went BACKWARDS, 93%
# to 92% over five hours, because the runner builds while rclone walks it.
#
# container-storage-prune.service now keeps the newest KEEP (2) tagged images
# per repository, clocked by a Kagetora Host Job. This check is not that job's
# trigger: pruning on a schedule and alerting when a known-fixable condition
# appears are different things, and using an alert as a cron is how you end up
# with cleanup that only happens if the alert pipeline is healthy. This watches
# for the prune having STOPPED working, which is the part nothing else notices.
# Whether the last run failed is Host Units Watch's business, through the unit's
# own result; this is the slower truth, that the stores are climbing again.
#
# WHY IMAGES AND NOT THE WHOLE TREE. `podman system df` splits images from
# volumes, and only images are what the prune controls. developer1's store is
# 2.85 GB of images and a 7.26 GB volume -- crunchtools-hook-cache, the mypy and
# uv cache. That volume is supposed to be big; pruning it would slow every
# pre-commit run for disk we are not short of (/var is 943 GB at 15%). Summing
# the whole tree would bury the signal under it.
#
# WHY gha-runner-cached IS CONTEXT, NOT ALERTED ON. Its unit calls it a
# "persistent layer cache" and its 17.4 GiB is the point. The prune only takes
# dangling layers there, so its size is not evidence of anything and is reported
# without counting toward the thresholds.
#
# Store metadata, not a filesystem walk: all four answer in about 2s, so this
# runs in the fast NRPE pool without the memory spike that OOM-killed the
# daemon when check_backup_freshness listed pCloud live (RT #1459).
#
# A service that is down is reported and skipped, not failed: gha-runner-cached
# runs with --rm and Restart=always, so it is legitimately absent for a few
# seconds between CI jobs.

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
WARN_GB=${1:-24}
CRIT_GB=${2:-36}
shift 2 2>/dev/null
ALERTED=${ALERTED:-"developer1 developer2 developer3"}
CONTEXT=${CONTEXT:-"gha-runner-cached"}
[ $# -gt 0 ] && ALERTED="$*" && CONTEXT=""

# images_bytes <svc> -> "<raw-bytes> <count>", or empty when it cannot be read
images_bytes() {
    local raw
    raw=$("$EXEC" "$1.crunchtools.com" podman system df --format json 2>/dev/null) || return 1
    [ -n "$raw" ] || return 1
    # The Images object is first in podman's output; take the first match of each.
    local size count
    size=$(grep -oE '"RawSize":[0-9]+' <<< "$raw" | head -1 | cut -d: -f2)
    count=$(grep -oE '"TotalCount":[0-9]+' <<< "$raw" | head -1 | cut -d: -f2)
    [ -n "$size" ] && [ -n "$count" ] || return 1
    echo "$size $count"
}

gb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }

total=0; parts=""; perf=""; down=""; unknown=0
for svc in $ALERTED; do
    if out=$(images_bytes "$svc"); then
        set -- $out
        total=$((total + $1))
        parts="${parts:+$parts, }$svc $(gb "$1")G/$2"
        perf="${perf:+$perf }${svc}_images=$1B ${svc}_count=$2"
    else
        down="${down:+$down, }$svc"
        unknown=$((unknown + 1))
    fi
done

for svc in $CONTEXT; do
    if out=$(images_bytes "$svc"); then
        set -- $out
        parts="${parts:+$parts, }$svc $(gb "$1")G/$2 (cache, not counted)"
        perf="${perf:+$perf }${svc}_images=$1B ${svc}_count=$2"
    else
        down="${down:+$down, }$svc"
    fi
done

# Every alerted store unreadable means we are measuring nothing.
if [ "$unknown" -ge "$(set -- $ALERTED; echo $#)" ]; then
    echo "CONTAINER STORAGE UNKNOWN - no alerted store could be read (down: ${down:-none})"
    exit 3
fi

total_gb=$(gb "$total")
warn_b=$((WARN_GB * 1073741824)); crit_b=$((CRIT_GB * 1073741824))
perf="$perf alerted_images=${total}B;${warn_b};${crit_b}"
tail="$parts${down:+; not running: $down}"

if [ "$total" -ge "$crit_b" ]; then
    echo "CONTAINER STORAGE CRITICAL - sandbox images ${total_gb}G (crit ${CRIT_GB}G): $tail | $perf"
    exit 2
elif [ "$total" -ge "$warn_b" ]; then
    echo "CONTAINER STORAGE WARNING - sandbox images ${total_gb}G (warn ${WARN_GB}G), is container-storage-prune running?: $tail | $perf"
    exit 1
fi
echo "CONTAINER STORAGE OK - sandbox images ${total_gb}G of ${WARN_GB}G: $tail | $perf"
exit 0
