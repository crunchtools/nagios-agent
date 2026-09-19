#!/bin/bash
# Check Temporal server health inside a container
# Temporal exposes a gRPC health endpoint; we check via the frontend HTTP API
# Usage: check_container_temporal.sh <container>

CONTAINER="$1"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container>"
    exit 3
fi

RESULT=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 "http://127.0.0.1:7233/health" 2>&1)

if [ "$RESULT" = "200" ]; then
    echo "OK - Temporal server in $CONTAINER is healthy"
    exit 0
elif [ "$RESULT" = "000" ]; then
    echo "CRITICAL - Temporal server in $CONTAINER unreachable on port 7233"
    exit 2
else
    ALIVE=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" pgrep -c -f temporal-server 2>/dev/null)
    if [ "${ALIVE:-0}" -gt 0 ]; then
        echo "WARNING - Temporal in $CONTAINER: process running but health returned HTTP $RESULT"
        exit 1
    else
        echo "CRITICAL - Temporal server in $CONTAINER is not running"
        exit 2
    fi
fi
