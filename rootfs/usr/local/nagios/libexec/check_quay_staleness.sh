#!/bin/bash
# Check if a Quay.io image is stale (older than N days)
# Usage: check_quay_staleness.sh <org/repo> <max-days> <tag>

REPO="$1"
MAX_DAYS="${2:-7}"
TAG="${3:-latest}"

MODIFIED=$(curl -s "https://quay.io/api/v1/repository/${REPO}/tag/?limit=1&specificTag=${TAG}&onlyActiveTags=true" 2>/dev/null | \
  python3 -c "
import sys, json, time, email.utils
d = json.load(sys.stdin)
tags = d.get('tags', [])
if not tags:
    print('UNKNOWN')
    sys.exit()
mod_str = tags[0].get('last_modified', '')
mod_time = email.utils.parsedate_to_datetime(mod_str).timestamp()
age_days = int((time.time() - mod_time) / 86400)
print(age_days)
" 2>/dev/null)

if [ -z "$MODIFIED" ] || [ "$MODIFIED" = "UNKNOWN" ]; then
    echo "UNKNOWN - Cannot query Quay API for $REPO:$TAG"
    exit 3
fi

if [ "$MODIFIED" -ge "$MAX_DAYS" ]; then
    echo "WARNING - $REPO:$TAG is ${MODIFIED} days old [threshold: ${MAX_DAYS}d] | age=${MODIFIED}d;${MAX_DAYS};;0"
    exit 1
else
    echo "OK - $REPO:$TAG is ${MODIFIED} days old | age=${MODIFIED}d;${MAX_DAYS};;0"
    exit 0
fi
