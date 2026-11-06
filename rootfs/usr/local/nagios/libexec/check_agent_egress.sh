#!/bin/bash
# Check that an agent container still holds a connection out through its gateway.
# Usage: check_agent_egress.sh <container> <host:port|http://host:port> [min_crit]
#
# WHY THIS EXISTS. On 2026-11-05 josui.crunchtools.com ran for nineteen hours
# with a live `claude remote-control` process holding ZERO sockets: the
# Trentina gateway had restarted, the client never came back, and nothing
# noticed. The container was up, the process was up, the unit was happy, and
# the agent was simply gone from the operator's session list. The only honest
# witness was /proc/net/tcp. (RT#1556)
#
# NO EXEC, like check_container_process_count.sh: an API exec session leaves
# two conmon processes on the host for five minutes, which at a one-minute
# interval is most of what "Host total processes" ends up counting. The
# container's main PID comes from the API, and this agent runs --pid=host, so
# /proc/<pid>/net/tcp IS the container's network namespace as the container
# sees it. Nothing has to exist inside the target.

CONTAINER="$1"
ENDPOINT="$2"
MIN_CRIT="${3:-1}"

if [ -z "$CONTAINER" ] || [ -z "$ENDPOINT" ]; then
    echo "UNKNOWN - Usage: $0 <container> <host:port|http://host:port> [min_crit]"
    exit 3
fi

if ! [[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "UNKNOWN - invalid container name '$CONTAINER'"
    exit 3
fi

# /proc/net/tcp writes the address little-endian and the port big-endian, so
# 10.89.15.2:8021 is 020F590A:1F55. Out-of-range values are refused rather
# than formatted into an endpoint that can never match, which would read as a
# dead connection for ever.
STRIPPED="${ENDPOINT#*://}"
STRIPPED="${STRIPPED%%/*}"
HOST="${STRIPPED%%:*}"
PORT="${STRIPPED##*:}"

if [ "$PORT" = "$HOST" ] || ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "UNKNOWN - '$ENDPOINT' has no usable port"
    exit 3
fi
if ! [[ "$HOST" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    echo "UNKNOWN - '$ENDPOINT' is not an IPv4 address; this check reads /proc, not DNS"
    exit 3
fi
OCT_A="${BASH_REMATCH[1]}"
OCT_B="${BASH_REMATCH[2]}"
OCT_C="${BASH_REMATCH[3]}"
OCT_D="${BASH_REMATCH[4]}"
for octet in "$OCT_A" "$OCT_B" "$OCT_C" "$OCT_D"; do
    if [ "$octet" -gt 255 ]; then
        echo "UNKNOWN - '$ENDPOINT' has an octet above 255"
        exit 3
    fi
done
TARGET=$(printf '%02X%02X%02X%02X:%04X' "$OCT_D" "$OCT_C" "$OCT_B" "$OCT_A" "$PORT")

SOCK="/run/podman/podman.sock"
RAW=$(curl -sS --max-time 10 --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/containers/${CONTAINER}/json" 2>&1)
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "UNKNOWN - $CONTAINER: podman inspect request failed (curl exit ${RC}): ${RAW}"
    exit 3
fi

PID=$(printf '%s' "$RAW" | grep -oP '"Pid"\s*:\s*\K[0-9]+' | head -1)
if [ -z "$PID" ] || [ "$PID" = "0" ]; then
    ERRMSG=$(printf '%s' "$RAW" | grep -oP '"message"\s*:\s*"\K[^"]+')
    echo "CRITICAL - $CONTAINER is not running${ERRMSG:+: $ERRMSG}"
    exit 2
fi

# STUB_NET_TCP is the test seam: /proc/<pid>/net/tcp cannot be faked, and a
# check whose only logic is "read this file and count" is not worth shipping
# untested.
NET_TCP="${STUB_NET_TCP:-/proc/${PID}/net/tcp}"
if [ ! -r "$NET_TCP" ]; then
    echo "UNKNOWN - $CONTAINER: cannot read $NET_TCP (is this agent --pid=host?)"
    exit 3
fi

# Column 3 is the remote address, column 4 the state; 01 is ESTABLISHED.
COUNT=$(awk -v target="$TARGET" \
    'NR > 1 && $3 == target && $4 == "01" { n++ } END { print n + 0 }' "$NET_TCP")

PERFDATA="egress_connections=${COUNT};${MIN_CRIT}:;${MIN_CRIT}:;0;"

if [ "$COUNT" -lt "$MIN_CRIT" ]; then
    echo "CRITICAL - $CONTAINER holds no connection to ${HOST}:${PORT}: the agent is alive and unreachable | $PERFDATA"
    exit 2
fi

echo "OK - $CONTAINER holds ${COUNT} connection(s) to ${HOST}:${PORT} | $PERFDATA"
exit 0
