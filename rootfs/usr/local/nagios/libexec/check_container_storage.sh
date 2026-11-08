#!/bin/bash
# check_container_storage.sh — watch the nested podman image stores (pure bash)
#
# Usage: check_container_storage.sh [warn-GB] [crit-GB] [service ...]
#
#   warn-GB, crit-GB   optional, default 24 and 36. They apply to the SUM of the
#                      alerted services' image bytes, not to any one store.
#   service ...        optional. Naming services REPLACES the default alerted
#                      set (developer1 developer2 developer3) AND clears the
#                      context-only set (gha-runner-cached), so everything named
#                      counts toward the thresholds. Env ALERTED and CONTEXT set
#                      the two lists independently.
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
# appears are different things, and using an alert as a cron means cleanup only
# happens while the alert pipeline is healthy. This watches for the prune having
# STOPPED working, which is the part nothing else notices. Whether the last run
# failed is Host Units Watch's business, through the unit's own result.
#
# WHY IMAGES AND NOT THE WHOLE TREE. `podman system df` reports images and
# volumes separately, and only images are what the prune controls. developer1's
# store is 2.85 GB of images and a 7.26 GB volume -- crunchtools-hook-cache, the
# mypy and uv cache. That volume is supposed to be big; pruning it would slow
# every pre-commit run for disk we are not short of (/var is 943 GB at 15%).
# Summing the whole tree would bury the signal under it.
#
# WHY gha-runner-cached IS CONTEXT, NOT ALERTED ON. Its unit calls it a
# "persistent layer cache" and its 17.4 GiB is the point. The prune only takes
# dangling layers there, so its size is not evidence of anything and is reported
# without counting toward the thresholds.
#
# Store metadata, not a filesystem walk: all four answer in about 2s, so this
# runs in the fast NRPE pool without the memory spike that OOM-killed the
# daemon when check_backup_freshness listed pCloud live (RT #1459).

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
WARN_GB=${1:-24}
CRIT_GB=${2:-36}
shift 2 2>/dev/null
ALERTED=${ALERTED:-"developer1 developer2 developer3"}
CONTEXT=${CONTEXT:-"gha-runner-cached"}
# An explicit list is the whole list: there is no way to say "and also keep the
# default context service", and silently alerting on a cache would be worse.
[ $# -gt 0 ] && ALERTED="$*" && CONTEXT=""

REASON="" IB_SIZE=0 IB_COUNT=0

# images_bytes <svc> -> sets IB_SIZE and IB_COUNT and returns 0, or sets REASON
# and returns 1 (not running) or 2 (there, but unreadable).
#
# Globals, not a value on stdout: a $(command substitution) runs the function in
# a subshell, so a REASON set inside one never reaches the caller and every
# failure printed as an empty "()".
#
# Selects the row whose Type is Images rather than taking the first number in
# the output: podman reports Images, Containers and Local Volumes, and reading
# the volume row by accident would mean treating developer1's 7.26 GB
# crunchtools-hook-cache as images and going CRITICAL on a healthy store.
#
# podman_exec.sh reports a failure as "EXEC_ERROR: ..." on stdout and still
# exits 0, so the exit status alone proves nothing and the text has to be read.
images_bytes() {
    local raw row size count
    raw=$("$EXEC" "$1.crunchtools.com" podman system df \
        --format '{{.Type}}|{{.RawSize}}|{{.Total}}' 2>&1)

    case "$raw" in
        *"EXEC_ERROR: Cannot create exec in container"*)
            # The container is not there. For these services that is an ordinary
            # idle state, not a fault: gha-runner-cached runs with --rm and
            # Restart=always, so it is legitimately absent between CI jobs.
            REASON="not running"; return 1 ;;
        *EXEC_ERROR*)
            # Anything else from the exec path -- a dead socket, a podman error
            # -- means we are blind on this store, which is not the same thing.
            REASON="exec failed: $(tr -d '\n' <<< "${raw#*EXEC_ERROR: }" | cut -c1-60)"
            return 2 ;;
    esac

    row=$(grep -m1 '^Images|' <<< "$raw")
    if [ -z "$row" ]; then
        REASON="no Images row: $(tr -d '\n' <<< "$raw" | cut -c1-60)"
        return 2
    fi
    IFS='|' read -r _ size count <<< "$row"
    if ! [[ $size =~ ^[0-9]+$ ]] || ! [[ $count =~ ^[0-9]+$ ]]; then
        REASON="unparseable Images row: $(tr -d '\n' <<< "$row" | cut -c1-60)"
        return 2
    fi
    IB_SIZE=$size IB_COUNT=$count
    return 0
}

gb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }

total=0; parts=""; perf=""; absent=""; errored=""; readable=0; rc=0
for svc in $ALERTED; do
    images_bytes "$svc"; rc=$?
    if [ "$rc" -eq 0 ]; then
        total=$((total + IB_SIZE))
        readable=$((readable + 1))
        parts="${parts:+$parts, }$svc $(gb "$IB_SIZE")G/$IB_COUNT"
        perf="${perf:+$perf }${svc}_images=${IB_SIZE}B ${svc}_count=$IB_COUNT"
    elif [ "$rc" -eq 2 ]; then
        errored="${errored:+$errored, }$svc ($REASON)"
    else
        absent="${absent:+$absent, }$svc ($REASON)"
    fi
done

for svc in $CONTEXT; do
    images_bytes "$svc"; rc=$?
    if [ "$rc" -eq 0 ]; then
        parts="${parts:+$parts, }$svc $(gb "$IB_SIZE")G/$IB_COUNT (cache, not counted)"
        perf="${perf:+$perf }${svc}_images=${IB_SIZE}B ${svc}_count=$IB_COUNT"
    elif [ "$rc" -eq 2 ]; then
        errored="${errored:+$errored, }$svc ($REASON)"
    else
        absent="${absent:+$absent, }$svc ($REASON)"
    fi
done

tail="$parts"
[ -n "$absent" ]  && tail="${tail:+$tail; }idle: $absent"
[ -n "$errored" ] && tail="${tail:+$tail; }unreadable: $errored"

# Nothing measured, or a store we should be measuring could not be read: either
# way the number below is not the truth, and saying OK would be a lie.
if [ "$readable" -eq 0 ]; then
    echo "CONTAINER STORAGE UNKNOWN - no alerted store could be read: ${tail:-none}"
    exit 3
fi
if [ -n "$errored" ]; then
    echo "CONTAINER STORAGE UNKNOWN - a store could not be read: $tail"
    exit 3
fi

total_gb=$(gb "$total")
warn_b=$((WARN_GB * 1073741824)); crit_b=$((CRIT_GB * 1073741824))
perf="$perf alerted_images=${total}B;${warn_b};${crit_b}"

if [ "$total" -ge "$crit_b" ]; then
    echo "CONTAINER STORAGE CRITICAL - sandbox images ${total_gb}G (crit ${CRIT_GB}G): $tail | $perf"
    exit 2
elif [ "$total" -ge "$warn_b" ]; then
    echo "CONTAINER STORAGE WARNING - sandbox images ${total_gb}G (warn ${WARN_GB}G), is container-storage-prune running?: $tail | $perf"
    exit 1
fi
echo "CONTAINER STORAGE OK - sandbox images ${total_gb}G of ${WARN_GB}G: $tail | $perf"
exit 0
