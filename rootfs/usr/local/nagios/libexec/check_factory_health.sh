#!/bin/bash
# Check factory.crunchtools.com health endpoint
# Usage: check_factory_health.sh

RESPONSE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 http://127.0.0.1:8095/api/health 2>/dev/null)

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
