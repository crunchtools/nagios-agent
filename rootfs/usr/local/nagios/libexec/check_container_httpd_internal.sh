#!/bin/bash
# Check Apache/Nginx/Caddy HTTP response inside a container
# Tests the actual web server, not just the process
# Usage: check_container_httpd_internal.sh <container> [port] [path] [expected_codes]

CONTAINER="$1"
PORT="${2:-80}"
PATH_URL="${3:-/}"
EXPECTED="${4:-200,301,302,401}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [port] [path] [expected_codes]"
    exit 3
fi

RESULT=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" curl -s -o /dev/null -w '%{http_code} %{time_total}' \
    --connect-timeout 5 --max-time 10 "http://127.0.0.1:${PORT}${PATH_URL}" 2>&1)
RC=$?

if [ $RC -ne 0 ] || [ -z "$RESULT" ]; then
    echo "CRITICAL - HTTP in $CONTAINER port $PORT unreachable"
    exit 2
fi

CODE=$(echo "$RESULT" | awk '{print $1}')
TIME=$(echo "$RESULT" | awk '{print $2}')

if echo ",$EXPECTED," | grep -q ",$CODE,"; then
    echo "OK - HTTP in $CONTAINER: ${CODE} on port ${PORT} (${TIME}s) | response_time=${TIME}s;;;0; http_code=${CODE};;;0;"
    exit 0
elif [ "$CODE" = "000" ]; then
    echo "CRITICAL - HTTP in $CONTAINER port $PORT: connection refused"
    exit 2
else
    echo "CRITICAL - HTTP in $CONTAINER port $PORT: unexpected ${CODE} | response_time=${TIME}s;;;0; http_code=${CODE};;;0;"
    exit 2
fi
