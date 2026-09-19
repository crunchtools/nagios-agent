#!/bin/bash
# Simple ping check using system ping (no Nagios plugin needed)
# Usage: check_ping_host.sh <host> <warn-ms> <crit-ms>

HOST="$1"
WARN="${2:-100}"
CRIT="${3:-500}"

OUTPUT=$(ping -c 3 -W 5 "$HOST" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    echo "CRITICAL - $HOST unreachable | rta=0ms;${WARN};${CRIT};0;"
    exit 2
fi

RTT=$(echo "$OUTPUT" | grep 'rtt\|round-trip' | grep -oP '[\d.]+' | head -2 | tail -1)
LOSS=$(echo "$OUTPUT" | grep -oP '[\d.]+(?=% packet loss)')

if [ -z "$RTT" ]; then RTT=0; fi
RTT_INT=${RTT%.*}

if [ "${LOSS%.*}" -ge 50 ]; then
    echo "CRITICAL - $HOST ${LOSS}% loss, ${RTT}ms avg | rta=${RTT}ms;${WARN};${CRIT};0; loss=${LOSS}%;50;80;0;100"
    exit 2
elif [ "$RTT_INT" -ge "$CRIT" ]; then
    echo "CRITICAL - $HOST ${RTT}ms avg, ${LOSS}% loss | rta=${RTT}ms;${WARN};${CRIT};0; loss=${LOSS}%;50;80;0;100"
    exit 2
elif [ "$RTT_INT" -ge "$WARN" ]; then
    echo "WARNING - $HOST ${RTT}ms avg, ${LOSS}% loss | rta=${RTT}ms;${WARN};${CRIT};0; loss=${LOSS}%;50;80;0;100"
    exit 1
else
    echo "OK - $HOST ${RTT}ms avg, ${LOSS}% loss | rta=${RTT}ms;${WARN};${CRIT};0; loss=${LOSS}%;50;80;0;100"
    exit 0
fi
