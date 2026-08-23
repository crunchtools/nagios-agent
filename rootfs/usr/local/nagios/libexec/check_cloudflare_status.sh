#!/bin/bash
# Check Cloudflare zone health via Analytics API
# Usage: check_cloudflare_status.sh <zone-id> <domain-name>
# Reads CLOUDFLARE_API_TOKEN from /etc/nagios/cloudflare.token

ZONE_ID="$1"
DOMAIN="$2"
TOKEN=$(cat /etc/nagios/cloudflare.token 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "UNKNOWN - Cannot read /etc/nagios/cloudflare.token"
    exit 3
fi

RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/analytics/dashboard?since=-1440&until=0" 2>/dev/null)

if ! echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "UNKNOWN - Invalid response from Cloudflare API"
    exit 3
fi

TOTALS=$(echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
t = d.get('result', {}).get('totals', {}).get('requests', {})
total = t.get('all', 0)
cached = t.get('cached', 0)
errs = sum(v for k, v in t.get('http_status', {}).items() if int(k) >= 500)
pct_err = (errs * 100 // total) if total > 0 else 0
pct_cached = (cached * 100 // total) if total > 0 else 0
print(f'{total} {cached} {errs} {pct_err} {pct_cached}')
" 2>/dev/null)

if [ -z "$TOTALS" ]; then
    echo "UNKNOWN - Cannot parse Cloudflare analytics for $DOMAIN"
    exit 3
fi

read -r TOTAL CACHED ERRS PCT_ERR PCT_CACHED <<< "$TOTALS"

PERFDATA="requests=${TOTAL};;;0; cached=${CACHED};;;0; errors=${ERRS};;;0; cache_pct=${PCT_CACHED}%;;;0;100"

if [ "$PCT_ERR" -ge 10 ]; then
    echo "CRITICAL - $DOMAIN: ${PCT_ERR}% server errors [${ERRS}/${TOTAL} requests, ${PCT_CACHED}% cached] | $PERFDATA"
    exit 2
elif [ "$PCT_ERR" -ge 2 ]; then
    echo "WARNING - $DOMAIN: ${PCT_ERR}% server errors [${ERRS}/${TOTAL} requests, ${PCT_CACHED}% cached] | $PERFDATA"
    exit 1
else
    echo "OK - $DOMAIN: ${TOTAL} requests, ${PCT_CACHED}% cached, ${PCT_ERR}% errors | $PERFDATA"
    exit 0
fi
