#!/bin/bash
# Check network throughput from /proc/net/dev
# Usage: check_net_throughput.sh [-i interface] [-w warn_mbps] [-c crit_mbps]
# Requires two runs to establish a baseline (uses state file for delta)

IFACE="eth0"
WARN=800
CRIT=950
STATE_DIR=/tmp/nagios-state

while getopts "i:w:c:" opt; do
    case $opt in
        i) IFACE=$OPTARG ;;
        w) WARN=$OPTARG ;;
        c) CRIT=$OPTARG ;;
    esac
done

LINE=$(awk -v iface="${IFACE}:" '$1==iface' /proc/net/dev)
if [ -z "$LINE" ]; then
    echo "UNKNOWN - Interface $IFACE not found in /proc/net/dev"
    exit 3
fi

NOW=$(date +%s)
RX_BYTES=$(echo "$LINE" | awk '{print $2}')
TX_BYTES=$(echo "$LINE" | awk '{print $10}')

mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/net_${IFACE}"

if [ ! -f "$STATE_FILE" ]; then
    echo "${NOW} ${RX_BYTES} ${TX_BYTES}" > "$STATE_FILE"
    echo "OK - First run for $IFACE, collecting baseline"
    exit 0
fi

read -r PREV_TIME PREV_RX PREV_TX < "$STATE_FILE"
echo "${NOW} ${RX_BYTES} ${TX_BYTES}" > "$STATE_FILE"

ELAPSED=$((NOW - PREV_TIME))
if [ "$ELAPSED" -le 0 ]; then
    echo "UNKNOWN - No time elapsed since last check"
    exit 3
fi

D_RX=$((RX_BYTES - PREV_RX))
D_TX=$((TX_BYTES - PREV_TX))

RX_BPS=$((D_RX / ELAPSED))
TX_BPS=$((D_TX / ELAPSED))
RX_MBPS=$((RX_BPS * 8 / 1000000))
TX_MBPS=$((TX_BPS * 8 / 1000000))
TOTAL_MBPS=$((RX_MBPS + TX_MBPS))

RX_KBS=$((RX_BPS / 1024))
TX_KBS=$((TX_BPS / 1024))

PERFDATA="rx=${RX_MBPS}Mbps tx=${TX_MBPS}Mbps rx_bytes=${RX_KBS}KB/s tx_bytes=${TX_KBS}KB/s total=${TOTAL_MBPS}Mbps;${WARN};${CRIT}"

if [ "$TOTAL_MBPS" -ge "$CRIT" ]; then
    echo "CRITICAL - $IFACE ${TOTAL_MBPS}Mbps [rx:${RX_MBPS}Mbps tx:${TX_MBPS}Mbps] | ${PERFDATA}"
    exit 2
elif [ "$TOTAL_MBPS" -ge "$WARN" ]; then
    echo "WARNING - $IFACE ${TOTAL_MBPS}Mbps [rx:${RX_MBPS}Mbps tx:${TX_MBPS}Mbps] | ${PERFDATA}"
    exit 1
else
    echo "OK - $IFACE ${TOTAL_MBPS}Mbps [rx:${RX_MBPS}Mbps tx:${TX_MBPS}Mbps] | ${PERFDATA}"
    exit 0
fi
