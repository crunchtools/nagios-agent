#!/bin/bash
# Check Cloudflare is actively proxying our domain via cdn-cgi/trace
# Usage: check_cloudflare_proxy.sh <domain>

DOMAIN="${1:-crunchtools.com}"

TRACE=$(curl -s --connect-timeout 10 --max-time 15 "https://${DOMAIN}/cdn-cgi/trace" 2>/dev/null)

if [ -z "$TRACE" ]; then
    echo "CRITICAL - No response from ${DOMAIN}/cdn-cgi/trace"
    exit 2
fi

COLO=$(echo "$TRACE" | grep '^colo=' | cut -d= -f2)
HTTP=$(echo "$TRACE" | grep '^http=' | cut -d= -f2)
TLS=$(echo "$TRACE" | grep '^tls=' | cut -d= -f2)

if [ -z "$COLO" ]; then
    echo "CRITICAL - cdn-cgi/trace returned but no colo (not proxied?)"
    exit 2
fi

echo "OK - ${DOMAIN} proxied via Cloudflare ${COLO}, ${HTTP}, ${TLS} | colo=${COLO}"
exit 0
