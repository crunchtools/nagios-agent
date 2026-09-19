#!/bin/bash
# Check process count inside a container matches expectations
# Useful for Node.js worker pools, PHP-FPM pools, Nginx workers
# Usage: check_container_process_count.sh <container> <pattern> <min_warn> <min_crit> [label]

CONTAINER="$1"
PATTERN="$2"
MIN_WARN="${3:-2}"
MIN_CRIT="${4:-1}"
LABEL="${5:-$PATTERN}"

if [ -z "$CONTAINER" ] || [ -z "$PATTERN" ]; then
    echo "UNKNOWN - Usage: $0 <container> <grep-pattern> <min_warn> <min_crit> [label]"
    exit 3
fi

COUNT=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" pgrep -c -f "$PATTERN" 2>/dev/null)
RC=$?

if [ $RC -ne 0 ] || [ -z "$COUNT" ]; then
    COUNT=0
fi

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
