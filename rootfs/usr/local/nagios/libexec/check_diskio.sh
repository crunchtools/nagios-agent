#!/bin/bash
# Check disk I/O rates and utilization from /proc/diskstats
# Usage: check_diskio.sh [-d device] [-w warn_util%] [-c crit_util%]
# Requires two runs to establish a baseline (uses state file for delta)

DEVICE=""
WARN=80
CRIT=95
STATE_DIR=/tmp/nagios-state

while getopts "d:w:c:" opt; do
    case $opt in
        d) DEVICE=$OPTARG ;;
        w) WARN=$OPTARG ;;
        c) CRIT=$OPTARG ;;
    esac
done

if [ -z "$DEVICE" ]; then
    DEVICE=$(awk '$2=="/" {print $1}' /proc/mounts | head -1 | sed 's|/dev/||; s/[0-9]*$//')
fi

if [ -z "$DEVICE" ]; then
    echo "UNKNOWN - Could not determine root device"
    exit 3
fi

LINE=$(awk -v dev="$DEVICE" '$3==dev' /proc/diskstats)
if [ -z "$LINE" ]; then
    echo "UNKNOWN - Device $DEVICE not found in /proc/diskstats"
    exit 3
fi

NOW=$(date +%s)
READS=$(echo "$LINE" | awk '{print $4}')
SECTORS_READ=$(echo "$LINE" | awk '{print $6}')
WRITES=$(echo "$LINE" | awk '{print $8}')
SECTORS_WRITTEN=$(echo "$LINE" | awk '{print $10}')
IO_MS=$(echo "$LINE" | awk '{print $13}')

mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/diskio_${DEVICE}"

if [ ! -f "$STATE_FILE" ]; then
    echo "${NOW} ${READS} ${SECTORS_READ} ${WRITES} ${SECTORS_WRITTEN} ${IO_MS}" > "$STATE_FILE"
    echo "OK - First run for $DEVICE, collecting baseline"
    exit 0
fi

read -r PREV_TIME PREV_READS PREV_SECTORS_R PREV_WRITES PREV_SECTORS_W PREV_IO_MS < "$STATE_FILE"
echo "${NOW} ${READS} ${SECTORS_READ} ${WRITES} ${SECTORS_WRITTEN} ${IO_MS}" > "$STATE_FILE"

ELAPSED=$((NOW - PREV_TIME))
if [ "$ELAPSED" -le 0 ]; then
    echo "UNKNOWN - No time elapsed since last check"
    exit 3
fi

ELAPSED_MS=$((ELAPSED * 1000))
D_READS=$((READS - PREV_READS))
D_WRITES=$((WRITES - PREV_WRITES))
D_SECTORS_R=$((SECTORS_READ - PREV_SECTORS_R))
D_SECTORS_W=$((SECTORS_WRITTEN - PREV_SECTORS_W))
D_IO_MS=$((IO_MS - PREV_IO_MS))

READ_IOPS=$((D_READS / ELAPSED))
WRITE_IOPS=$((D_WRITES / ELAPSED))
READ_KBS=$((D_SECTORS_R * 512 / 1024 / ELAPSED))
WRITE_KBS=$((D_SECTORS_W * 512 / 1024 / ELAPSED))
UTIL=$((D_IO_MS * 100 / ELAPSED_MS))

if [ "$UTIL" -gt 100 ]; then
    UTIL=100
fi

PERFDATA="read_iops=${READ_IOPS} write_iops=${WRITE_IOPS} read_kbs=${READ_KBS}KB/s write_kbs=${WRITE_KBS}KB/s util=${UTIL}%;${WARN};${CRIT};0;100"

if [ "$UTIL" -ge "$CRIT" ]; then
    echo "CRITICAL - $DEVICE ${UTIL}% util [r:${READ_KBS}KB/s w:${WRITE_KBS}KB/s riops:${READ_IOPS} wiops:${WRITE_IOPS}] | ${PERFDATA}"
    exit 2
elif [ "$UTIL" -ge "$WARN" ]; then
    echo "WARNING - $DEVICE ${UTIL}% util [r:${READ_KBS}KB/s w:${WRITE_KBS}KB/s riops:${READ_IOPS} wiops:${WRITE_IOPS}] | ${PERFDATA}"
    exit 1
else
    echo "OK - $DEVICE ${UTIL}% util [r:${READ_KBS}KB/s w:${WRITE_KBS}KB/s riops:${READ_IOPS} wiops:${WRITE_IOPS}] | ${PERFDATA}"
    exit 0
fi
