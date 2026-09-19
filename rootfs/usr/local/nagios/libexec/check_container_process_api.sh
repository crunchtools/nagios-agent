#!/bin/bash
# Check process count inside a container via Podman API /top endpoint
# Works even when containers have no ps/pgrep installed
# Usage: check_container_process_api.sh <container> <grep-pattern> <min_warn> <min_crit> [label]

CONTAINER="$1"
PATTERN="$2"
MIN_WARN="${3:-2}"
MIN_CRIT="${4:-1}"
LABEL="${5:-$PATTERN}"
SOCK="/run/podman/podman.sock"

if [ -z "$CONTAINER" ] || [ -z "$PATTERN" ]; then
    echo "UNKNOWN - Usage: $0 <container> <grep-pattern> <min_warn> <min_crit> [label]"
    exit 3
fi

RAW=$(curl -s --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/containers/${CONTAINER}/top?ps_args=aux" 2>/dev/null)

if echo "$RAW" | grep -q '"cause"'; then
    echo "UNKNOWN - Container '$CONTAINER' not found or not running"
    exit 3
fi

COUNT=$(echo "$RAW" | tr -d '\000-\010' | grep -oP '"[^"]*'"$PATTERN"'[^"]*"' | wc -l)

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
