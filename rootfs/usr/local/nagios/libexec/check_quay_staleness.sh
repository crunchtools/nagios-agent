#!/bin/bash
# Check if a Quay.io image is stale (pure bash)
# Usage: check_quay_staleness.sh <org/repo> <max-days> <tag>

REPO="$1"
MAX_DAYS="${2:-7}"
TAG="${3:-latest}"

RESPONSE=$(curl -s "https://quay.io/api/v1/repository/${REPO}/tag/?limit=1&specificTag=${TAG}&onlyActiveTags=true" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo "UNKNOWN - Cannot query Quay API for $REPO:$TAG"
    exit 3
fi

MODIFIED=$(echo "$RESPONSE" | grep -oP '"last_modified":\s*"\K[^"]+' | head -1)

if [ -z "$MODIFIED" ]; then
    echo "UNKNOWN - No tag data for $REPO:$TAG"
    exit 3
fi

MOD_EPOCH=$(date -d "$MODIFIED" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)

if [ -z "$MOD_EPOCH" ]; then
    echo "UNKNOWN - Cannot parse date: $MODIFIED"
    exit 3
fi

AGE_DAYS=$(( (NOW_EPOCH - MOD_EPOCH) / 86400 ))

if [ "$AGE_DAYS" -ge "$MAX_DAYS" ]; then
    echo "WARNING - $REPO:$TAG is ${AGE_DAYS} days old [threshold: ${MAX_DAYS}d] | age=${AGE_DAYS}d;${MAX_DAYS};;0"
    exit 1
else
    echo "OK - $REPO:$TAG is ${AGE_DAYS} days old | age=${AGE_DAYS}d;${MAX_DAYS};;0"
    exit 0
fi
