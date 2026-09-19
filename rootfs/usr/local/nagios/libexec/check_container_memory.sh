#!/bin/bash
# Check container memory usage via podman API socket (pure bash, no python)
# Usage: check_container_memory.sh <container-name> <warn%> <crit%>

NAME="$1"
WARN="${2:-85}"
CRIT="${3:-95}"
SOCK="/run/podman/podman.sock"

RAW=$(curl -s --unix-socket "$SOCK" "http://localhost/v5.0.0/containers/${NAME}/stats?stream=false" 2>/dev/null)

if echo "$RAW" | grep -q '"cause"'; then
    echo "UNKNOWN - Container '$NAME' not found or not running"
    exit 3
fi

USAGE=$(echo "$RAW" | grep -oP '"usage":\s*\K[0-9]+' | head -1)
LIMIT=$(echo "$RAW" | grep -oP '"limit":\s*\K[0-9]+' | head -1)

if [ -z "$USAGE" ] || [ -z "$LIMIT" ] || [ "$LIMIT" -eq 0 ]; then
    echo "UNKNOWN - Cannot parse stats for '$NAME'"
    exit 3
fi

USAGE_MB=$((USAGE / 1048576))
LIMIT_MB=$((LIMIT / 1048576))
PCT=$((USAGE * 100 / LIMIT))

PERFDATA="mem_pct=${PCT}%;${WARN};${CRIT};0;100 mem_used=${USAGE_MB}MB;;;0;${LIMIT_MB}"

if [ "$PCT" -ge "$CRIT" ]; then
    echo "CRITICAL - $NAME memory ${PCT}% [${USAGE_MB}MB/${LIMIT_MB}MB] | $PERFDATA"
    exit 2
elif [ "$PCT" -ge "$WARN" ]; then
    echo "WARNING - $NAME memory ${PCT}% [${USAGE_MB}MB/${LIMIT_MB}MB] | $PERFDATA"
    exit 1
else
    echo "OK - $NAME memory ${PCT}% [${USAGE_MB}MB/${LIMIT_MB}MB] | $PERFDATA"
    exit 0
fi
