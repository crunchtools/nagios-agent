#!/bin/bash
# Check Apache/Nginx/Caddy HTTP response inside a container
# Tests the actual web server, not just the process
# Usage: check_container_httpd_internal.sh <container> [port] [path] [expected_codes]
#   port: 1-65535 (default 80). path: must start with / and contain no @
#   (default /). Invalid port or path returns UNKNOWN.
#
# DIRECT FIRST, EXEC AS FALLBACK. The agent runs with --network=host, so a
# bridged container's IP is reachable from here without an exec session.
# Each API exec keeps two conmon processes alive on the host for
# exit_command_delay after it finishes; at a 1-minute interval these checks
# alone held ~100 standing processes on lotor. Exec is still used when the
# container has no bridge IP (host network) or the port only listens on the
# container's loopback (direct connect returns 000, e.g. acquacotta:5000).

CONTAINER="$1"
PORT="${2:-80}"
PATH_URL="${3:-/}"
EXPECTED="${4:-200,301,302,401}"
SOCK="/run/podman/podman.sock"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [port] [path] [expected_codes]"
    exit 3
fi

# PORT and PATH go into a URL fetched from the host network; keep them from
# rewriting the authority (e.g. PORT="80@elsewhere").
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "UNKNOWN - invalid port '$PORT'"
    exit 3
fi
if [[ "$PATH_URL" != /* ]] || [[ "$PATH_URL" == *@* ]]; then
    echo "UNKNOWN - invalid path '$PATH_URL'"
    exit 3
fi

IP=$(curl -s --max-time 5 --unix-socket "$SOCK" "http://localhost/v5.0.0/containers/${CONTAINER}/json" 2>/dev/null \
    | grep -oP '"IPAddress"\s*:\s*"\K[0-9.]+' | head -1)

RESULT=""
if [ -n "$IP" ]; then
    RESULT=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
        --connect-timeout 5 --max-time 10 "http://${IP}:${PORT}${PATH_URL}" 2>/dev/null)
fi

if [ -z "$RESULT" ] || [ "${RESULT%% *}" = "000" ]; then
    RESULT=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" curl -s -o /dev/null -w '%{http_code} %{time_total}' \
        --connect-timeout 5 --max-time 10 "http://127.0.0.1:${PORT}${PATH_URL}" 2>&1)
    RC=$?
    if [ $RC -ne 0 ] || [ -z "$RESULT" ]; then
        echo "CRITICAL - HTTP in $CONTAINER port $PORT unreachable"
        exit 2
    fi
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
