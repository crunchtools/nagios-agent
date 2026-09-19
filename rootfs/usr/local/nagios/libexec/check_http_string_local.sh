#!/bin/bash
# Check that an HTTP port on the host returns a response containing a specific string.
# Bypasses Cloudflare and the reverse proxy - tests the app container directly
# via the host port mapping, using the same TCP path the proxy uses internally.
# Catches app-level crashes (e.g. PM2 frontend crash-loop) that process-count
# and container-running checks miss because the container shell stays alive.
#
# Usage: check_http_string_local.sh <port> <expected_string> [path] [timeout]
# Example: check_http_string_local.sh 8092 Postiz / 15

PORT="$1"
EXPECTED_STRING="$2"
PATH_URL="${3:-/}"
TIMEOUT="${4:-15}"

if [ -z "$PORT" ] || [ -z "$EXPECTED_STRING" ]; then
    echo "UNKNOWN - Usage: $0 <port> <string> [path] [timeout]"
    exit 3
fi

BODY=$(curl -s -L --max-time "$TIMEOUT" --connect-timeout 5     "http://127.0.0.1:${PORT}${PATH_URL}" 2>/dev/null)
RC=$?

if [ $RC -ne 0 ] || [ -z "$BODY" ]; then
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --connect-timeout 3         "http://127.0.0.1:${PORT}${PATH_URL}" 2>/dev/null)
    echo "CRITICAL - http://127.0.0.1:${PORT}${PATH_URL} unreachable (curl: $RC, code: ${CODE:-000})"
    exit 2
fi

if echo "$BODY" | grep -q "$EXPECTED_STRING"; then
    echo "OK - '$EXPECTED_STRING' found at 127.0.0.1:${PORT}${PATH_URL}"
    exit 0
else
    echo "CRITICAL - '$EXPECTED_STRING' NOT found at 127.0.0.1:${PORT}${PATH_URL} (app returning error page or crashed)"
    exit 2
fi
