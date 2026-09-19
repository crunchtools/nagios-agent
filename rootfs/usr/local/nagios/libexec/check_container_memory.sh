#!/bin/bash
# Check container memory usage as percentage of its limit
# Usage: check_container_memory.sh <container-name> <warn%> <crit%>

NAME="$1"
WARN="${2:-85}"
CRIT="${3:-95}"

RAW=$(podman stats --no-stream --format '{{.MemUsage}} {{.MemPerc}}' "$NAME" 2>/dev/null)

if [ -z "$RAW" ]; then
    echo "UNKNOWN - Container '$NAME' not found or not running"
    exit 3
fi

USAGE=$(echo "$RAW" | awk '{print $1 "/" $3}')
PCT=$(echo "$RAW" | awk '{gsub(/%/,"",$NF); printf "%d", $NF}')

if [ "$PCT" -ge "$CRIT" ]; then
    echo "CRITICAL - Container $NAME memory ${PCT}% [$USAGE] | mem_pct=${PCT}%;${WARN};${CRIT};0;100"
    exit 2
elif [ "$PCT" -ge "$WARN" ]; then
    echo "WARNING - Container $NAME memory ${PCT}% [$USAGE] | mem_pct=${PCT}%;${WARN};${CRIT};0;100"
    exit 1
else
    echo "OK - Container $NAME memory ${PCT}% [$USAGE] | mem_pct=${PCT}%;${WARN};${CRIT};0;100"
    exit 0
fi
