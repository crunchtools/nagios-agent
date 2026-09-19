#!/bin/bash
# Check Cloudflare zone health via Analytics API (pure bash)
# Usage: check_cloudflare_status.sh <domain-name>
#
# The zone ID is looked up from /etc/nagios/cloudflare-zones.conf, never passed
# as an argument. This repo is public, and an nrpe.cfg carrying zone IDs inline
# cannot be committed without publishing which zones belong to this account.
# Zone IDs are not credentials — the API token is, and it lives in
# cloudflare.token — but there is no reason to publish them either.
#
# The conf is a host file bind-mounted into the agent, one zone per line:
#   <domain> <zone-id>
# Comments and blank lines are ignored.

DOMAIN="$1"
ZONES="${CF_ZONES:-/etc/nagios/cloudflare-zones.conf}"
TOKEN_FILE="${CF_TOKEN:-/etc/nagios/cloudflare.token}"

if [ -z "$DOMAIN" ]; then
    echo "UNKNOWN - usage: check_cloudflare_status.sh <domain-name>"
    exit 3
fi

if [ ! -r "$ZONES" ]; then
    echo "UNKNOWN - Cannot read $ZONES"
    exit 3
fi

ZONE_ID=$(awk -v d="$DOMAIN" '$1 !~ /^#/ && $1 == d { print $2; exit }' "$ZONES")

if [ -z "$ZONE_ID" ]; then
    echo "UNKNOWN - $DOMAIN has no zone ID in $ZONES"
    exit 3
fi

TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "UNKNOWN - Cannot read $TOKEN_FILE"
    exit 3
fi

RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/analytics/dashboard?since=-1440&until=0" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo "UNKNOWN - No response from Cloudflare API"
    exit 3
fi

TOTAL=$(echo "$RESPONSE" | grep -o '"all":[0-9]*' | head -1 | grep -o '[0-9]*')
CACHED=$(echo "$RESPONSE" | grep -o '"cached":[0-9]*' | head -1 | grep -o '[0-9]*')

if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
    echo "OK - $DOMAIN: no traffic in last 24h | requests=0;;;0;"
    exit 0
fi

PCT_CACHED=$((CACHED * 100 / TOTAL))

echo "OK - $DOMAIN: ${TOTAL} requests, ${PCT_CACHED}% cached | requests=${TOTAL};;;0; cached_pct=${PCT_CACHED}%;;;0;100"
exit 0
