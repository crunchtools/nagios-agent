#!/bin/bash
# rotation-progress-collect.sh — samples every in-flight pbs rotation (9.7.0)
# Usage: rotation-progress-collect.sh [container-name-prefix]
#
# WHY A COLLECTOR FOR A PURELY LOCAL READ
#
# Not for a slow read — every call here is the local podman socket. For a
# BASELINE. The question check_backup_rotation_progress.sh has to answer is
# "has this rotation moved at all since the last time we looked", and the only
# proof of movement that survives rclone's delete pass is the container's CPU
# time, which is a CUMULATIVE counter. One sample of a cumulative counter says
# nothing; two samples five minutes apart say everything.
#
# The alternative was sampling twice inside one check run with a sleep between.
# At the rate measured on 2026-11-09 — a personal rotation deep in a
# `--delete-during` pass against pCloud, burning about half a CPU-second a
# minute — a 15-second in-check sample expects 7 ticks of CPU and can easily
# read zero on a bursty process. That check would flap, and a flapping detector
# trains the operator to ignore it. Across a 45-minute window of five-minute
# samples the same rotation accrues ~22 CPU-seconds, so "zero increase for 45
# minutes" is not something a slow run reaches.
#
# Nagios is still the clock: the plugin starts this script detached through
# `podman_exec.sh --detach` when the status file is older than its REFRESH, and
# a flock stops two runs overlapping. No timer, no credential (constitution XVI).
#
# WHAT IT WRITES, $STATE_DIR/rotation-progress.status, replaced atomically:
#   ROTP generated=<epoch> elapsed=<s> items=<n>
#   ROTP item=<name> id=<12> started=<epoch> seen=<epoch> result=ok \
#        cpu=<cpu-seconds> cpu_moved=<epoch> stats_ts=<epoch> flat_ts=<epoch> \
#        flat_floor=<0|1> lines=<n> pay=<cleaned stats payload>
#   ROTP item=<name> id=<12> started=<epoch> seen=<epoch> result=error msg=<text>
#   ROTP end=1
#
# cpu_moved is the accumulator that makes the plugin stateless: it is carried
# forward from the previous file and moved to now only when cpu has INCREASED.
# So `now - cpu_moved` is how long the rotation has burned no CPU at all, and
# the plugin reads it off one line. Keyed on the container id, not the name, so
# a recycled name starts a fresh baseline instead of inheriting a dead run's.
#
# flat_ts is the same idea for bytes, but it needs no carry-forward: rclone's
# own per-minute stats lines are the history, so the timestamp of the first line
# of the current unchanged run is readable from the log every time.
#
# Facts only. Every threshold is the plugin's.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

PREFIX=${PREFIX:-${1:-pbs-}}
SOCK=${SOCK:-/run/podman/podman.sock}
API=${API:-http://localhost/v5.0.0}
TAIL=${TAIL:-600}          # log lines read back per rotation
STATUS=${STATUS:-$STATE_DIR/rotation-progress.status}

cl_lock rotation-progress

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

# A socket failure does NOT publish. The pCloud collectors keep their last good
# answers through a failed read because a slow pCloud is routine; a local podman
# socket that will not answer is not, and the plugin saying "collector stale" is
# the correct report of it. Publishing a file with the old samples and a fresh
# `generated` would hide exactly the outage worth seeing.
list=$(curl -s --max-time 10 --unix-socket "$SOCK" "$API/libpod/containers/json" 2>/dev/null) || exit 3
list=${list%"${list##*[![:space:]]}"}
case "$list" in
    \[*\]) ;;
    *) exit 3 ;;   # truncated or error body; see the bracket note in collector-lib.sh
esac

names=$(printf '%s' "$list" | grep -o '"Names":\[[^]]*\]' | grep -o '"[^"]*"' | grep -v Names | tr -d '"')

# Cumulative CPU seconds across every process in the container.
#
# /containers/{id}/top runs ps on the HOST against the container's PID
# namespace, so nothing has to exist inside the target and no exec session is
# created — the reason check_container_process_count.sh moved off podman_exec
# (RT #1493). `times` is whole CPU seconds and monotonic per process, so the sum
# is monotonic too. Echoes the total, or nothing when the table is unreadable.
container_cpu() {
    local raw n total=0
    raw=$(curl -s --max-time 10 --unix-socket "$SOCK" \
            "$API/containers/$1/top?ps_args=-eo%20times" 2>/dev/null) || return 1
    # Positive proof of a process table. A stopped or renamed container answers
    # {"cause":...}, which must never read as zero CPU — that is indistinguishable
    # from a wedge and would be a false alarm on a container that merely finished.
    printf '%s' "$raw" | grep -q '"Titles"' || return 1
    for n in $(printf '%s' "${raw%%\"Titles\"*}" | grep -oE '[0-9]+'); do
        total=$((total + n))
    done
    printf '%s' "$total"
}

# Newest rclone stats line, and the start of its current unchanged run.
#
# Every rotation runs rclone with `--stats 1m --stats-one-line
# --stats-log-level NOTICE`, so the container log carries one line a minute:
#   2026/11/09 06:33:35 NOTICE:    22.978 GiB / 22.978 GiB, 100%, 0 B/s, ETA -
#
# podman prepends an 8-byte frame header per line whose length bytes can be
# printable, so the parse anchors on the RFC3339 stamp --timestamps adds and on
# " NOTICE:", and takes the payload as everything after it. Frame garbage lands
# at the START of a line, ahead of both anchors, and the payload is at the end
# where it cannot be touched. Same approach as check_syslog_source_freshness.sh.
#
# Sets ST_TS, ST_PAY, ST_FLAT_TS, ST_FLAT_FLOOR, ST_LINES. ST_FLAT_FLOOR=1 means
# the unchanged run reaches the oldest line read, so its true length is at least
# what ST_FLAT_TS gives.
stats_window() {
    local body line ts pay last i flat
    local -a tss pays
    ST_LINES=0 ST_TS= ST_PAY= ST_FLAT_TS= ST_FLAT_FLOOR=0
    body=$(curl -s --max-time 10 --unix-socket "$SOCK" \
            "$API/libpod/containers/$1/logs?stdout=true&stderr=true&tail=$TAIL&timestamps=true" 2>/dev/null) || return 1

    # printf '%s\n', not '%s': podman's log body has no trailing newline, and
    # `read` returns non-zero on a last unterminated line after setting it, so
    # the loop body never sees it. With one stats line in the window that
    # silently emptied the window and reported a reporting rotation as silent.
    while IFS= read -r line; do
        [[ $line =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[0-9.]*([+-][0-9]{2}:[0-9]{2}|Z)).*NOTICE:[[:space:]]*(.*)$ ]] || continue
        ts=${BASH_REMATCH[1]}
        pay=${BASH_REMATCH[3]}
        pay=${pay%"${pay##*[![:space:]]}"}     # trailing whitespace and CR
        [ -n "$pay" ] || continue
        tss+=("$ts"); pays+=("$pay")
    done < <(printf '%s\n' "$body" | tr -d '\000-\010\013\014\016-\037')

    ST_LINES=${#tss[@]}
    [ "$ST_LINES" -gt 0 ] || return 0

    last=$((ST_LINES - 1))
    ST_PAY=${pays[$last]}
    ST_TS=$(date -d "${tss[$last]}" +%s 2>/dev/null) || ST_TS=
    [ -n "$ST_TS" ] || return 0

    flat=$last
    for ((i = last - 1; i >= 0; i--)); do
        [ "${pays[$i]}" = "$ST_PAY" ] || break
        flat=$i
    done
    [ "$flat" -eq 0 ] && ST_FLAT_FLOOR=1
    ST_FLAT_TS=$(date -d "${tss[$flat]}" +%s 2>/dev/null) || ST_FLAT_TS=
}

items=0
: > "$TMP/items"
for name in $names; do
    case "$name" in "$PREFIX"*) ;; *) continue ;; esac
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || continue

    raw=$(curl -s --max-time 5 --unix-socket "$SOCK" "$API/containers/$name/json" 2>/dev/null)
    id=$(printf '%s' "$raw" | grep -oE '"Id":"[0-9a-f]{12}' | head -1 | cut -d'"' -f4)
    started=$(printf '%s' "$raw" | grep -o '"StartedAt":"[^"]*"' | head -1 | cut -d'"' -f4)
    # The guard is on the string, not the epoch: `date -d ""` succeeds and
    # returns TODAY AT MIDNIGHT, so an error body came out as a plausible start
    # time rather than as a failure.
    started_epoch=""
    [ -n "$started" ] && started_epoch=$(date -d "$started" +%s 2>/dev/null)

    items=$((items + 1))
    head="ROTP item=$name id=${id:-unknown} started=${started_epoch:-0} seen=$(date +%s)"

    if [ -z "$started_epoch" ] || [ -z "$id" ]; then
        echo "$head result=error msg=$(cl_clean "inspect unreadable")" >> "$TMP/items"
        continue
    fi

    # Previous sample for THIS container id, for the cpu_moved carry-forward.
    prev=$(cl_previous "$STATUS" "^ROTP item=[^ ]+ id=$id " | head -1)
    prev_cpu=$(cl_field cpu "$prev")
    prev_moved=$(cl_field cpu_moved "$prev")

    if ! cpu=$(container_cpu "$name"); then
        # Carry cpu and cpu_moved so a transient top failure does not restart the
        # baseline, but report the error: the plugin turns result=error into
        # UNKNOWN for this rotation and never judges it on a sample it did not get.
        echo "$head result=error msg=$(cl_clean "podman top unreadable")${prev_cpu:+ cpu=$prev_cpu}${prev_moved:+ cpu_moved=$prev_moved}" >> "$TMP/items"
        continue
    fi

    if ! stats_window "$name"; then
        echo "$head result=error msg=$(cl_clean "container log unreadable") cpu=$cpu${prev_moved:+ cpu_moved=$prev_moved}" >> "$TMP/items"
        continue
    fi

    # The whole point of the file: cpu_moved advances only on a real increase.
    # No previous sample means no baseline, so it starts at now and the freeze
    # clock begins at zero — a fresh collector can never invent a stall.
    moved=$(date +%s)
    if [[ ${prev_cpu:-} =~ ^[0-9]+$ && ${prev_moved:-} =~ ^[0-9]+$ ]]; then
        [ "$cpu" -gt "$prev_cpu" ] || moved=$prev_moved
    fi

    echo "$head result=ok cpu=$cpu cpu_moved=$moved stats_ts=${ST_TS:-0} flat_ts=${ST_FLAT_TS:-0} flat_floor=$ST_FLAT_FLOOR lines=$ST_LINES pay=$(cl_clean "${ST_PAY:-none}")" >> "$TMP/items"
done

{
    echo "ROTP generated=$START elapsed=$(( $(date +%s) - START )) items=$items"
    cat "$TMP/items"
    echo "ROTP end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
