#!/bin/bash
# Check factory.crunchtools.com health endpoint
# Usage: check_factory_health.sh
#
# The route is /health, not /api/health. This asked for /api/health for months
# and always passed, because the dashboard serves its single-page app for any
# unmatched path — so a 200 meant "the web server answered", never "the health
# endpoint is alive". Found while wiring up check_factory_status.sh (RT #1478).
#
# This check only proves the dashboard process is serving. The watchdog's actual
# findings are a separate check: check_factory_status.sh.

RESPONSE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 http://127.0.0.1:8095/health 2>/dev/null)

if [ "$RESPONSE" = "200" ]; then
    echo "OK - Factory health endpoint returned 200"
    exit 0
elif [ "$RESPONSE" = "000" ]; then
    echo "CRITICAL - Factory health endpoint unreachable"
    exit 2
else
    echo "CRITICAL - Factory health endpoint returned HTTP $RESPONSE"
    exit 2
fi
