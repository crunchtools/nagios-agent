#!/bin/bash
# Check process count inside a container matches expectations
# Useful for Node.js worker pools, PHP-FPM pools, Nginx workers
# Usage: check_container_process_count.sh <container> <pattern> <min_warn> <min_crit> [label]
#
# NO EXEC. The old body ran `podman_exec.sh <ctr> pgrep -c -f <pattern>`.
# Every API exec session keeps two conmon processes alive on the host for
# exit_command_delay (300s by default) after the command finishes. At a
# 1-minute check interval across the fleet that was ~500 standing processes
# on lotor -- the monitoring was most of what "Host total processes" counted.
#
# Same approach as check_container_zombies.sh (RT #1493): the Engine API's
# /containers/{id}/top runs ps on the HOST against the container's PID
# namespace, so nothing needs to exist inside the target and no exec session
# is created. `args` is the full command line, which is what pgrep -f
# matched against; the pattern is still an extended regex.

CONTAINER="$1"
PATTERN="$2"
MIN_WARN="${3:-2}"
MIN_CRIT="${4:-1}"
LABEL="${5:-$PATTERN}"

if [ -z "$CONTAINER" ] || [ -z "$PATTERN" ]; then
    echo "UNKNOWN - Usage: $0 <container> <grep-pattern> <min_warn> <min_crit> [label]"
    exit 3
fi

SOCK="/run/podman/podman.sock"

RAW=$(curl -s --max-time 10 --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/containers/${CONTAINER}/top?ps_args=-eo%20pid%2Cargs" 2>&1)
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "UNKNOWN - $LABEL in $CONTAINER: podman top request failed (curl exit ${RC})"
    exit 3
fi

# Positive proof we got a process table. A stopped or renamed container
# returns {"cause":...,"message":...}, which must not read as zero processes.
if ! printf '%s' "$RAW" | grep -q '"Titles"'; then
    ERRMSG=$(printf '%s' "$RAW" | grep -oP '"message"\s*:\s*"\K[^"]+')
    echo "UNKNOWN - $LABEL in $CONTAINER: podman top failed${ERRMSG:+: $ERRMSG}"
    exit 3
fi

# Each row is ["<pid>","<args>"]. Match JSON strings properly (escaped
# quotes and backslashes) so a `]` or `","` inside a command line cannot end
# the row early. -o with \K keeps only the args column.
JSON_STR='"(?:[^"\\]|\\.)*"'
ARGS=$(printf '%s' "${RAW%%\"Titles\"*}" | grep -oP "\[${JSON_STR},\K${JSON_STR}(?=\])")

if [ -z "$ARGS" ]; then
    echo "UNKNOWN - $LABEL in $CONTAINER: podman top returned no process rows"
    exit 3
fi

COUNT=$(printf '%s\n' "$ARGS" | sed -E 's/^"(.*)"$/\1/' | grep -cE -- "$PATTERN")

PERFDATA="process_count=${COUNT};${MIN_WARN}:;${MIN_CRIT}:;0;"

if [ "$COUNT" -lt "$MIN_CRIT" ]; then
    echo "CRITICAL - $LABEL in $CONTAINER: ${COUNT} processes (minimum ${MIN_CRIT}) | $PERFDATA"
    exit 2
elif [ "$COUNT" -lt "$MIN_WARN" ]; then
    echo "WARNING - $LABEL in $CONTAINER: ${COUNT} processes (minimum ${MIN_WARN}) | $PERFDATA"
    exit 1
else
    echo "OK - $LABEL in $CONTAINER: ${COUNT} processes running | $PERFDATA"
    exit 0
fi
