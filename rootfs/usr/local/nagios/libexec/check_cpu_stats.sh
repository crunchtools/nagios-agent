#!/bin/bash
# Check CPU utilization breakdown from /proc/stat (iowait, steal, etc.)
# Usage: check_cpu_stats.sh [-W iowait_warn%] [-C iowait_crit%] [-s steal_warn%] [-S steal_crit%]
# Requires two runs to establish a baseline (uses state file for delta)

IOWAIT_WARN=20
IOWAIT_CRIT=40
STEAL_WARN=10
STEAL_CRIT=30
STATE_DIR=/tmp/nagios-state

while getopts "W:C:s:S:" opt; do
    case $opt in
        W) IOWAIT_WARN=$OPTARG ;;
        C) IOWAIT_CRIT=$OPTARG ;;
        s) STEAL_WARN=$OPTARG ;;
        S) STEAL_CRIT=$OPTARG ;;
    esac
done

CPU_LINE=$(head -1 /proc/stat)
if [ -z "$CPU_LINE" ]; then
    echo "UNKNOWN - Could not read /proc/stat"
    exit 3
fi

NOW=$(date +%s)
read -r _ USER NICE SYSTEM IDLE IOWAIT IRQ SOFTIRQ STEAL _ _ <<< "$CPU_LINE"

mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/cpu_stats"

if [ ! -f "$STATE_FILE" ]; then
    echo "${NOW} ${USER} ${NICE} ${SYSTEM} ${IDLE} ${IOWAIT} ${IRQ} ${SOFTIRQ} ${STEAL}" > "$STATE_FILE"
    echo "OK - First run, collecting baseline"
    exit 0
fi

read -r PREV_TIME PREV_USER PREV_NICE PREV_SYSTEM PREV_IDLE PREV_IOWAIT PREV_IRQ PREV_SOFTIRQ PREV_STEAL < "$STATE_FILE"
echo "${NOW} ${USER} ${NICE} ${SYSTEM} ${IDLE} ${IOWAIT} ${IRQ} ${SOFTIRQ} ${STEAL}" > "$STATE_FILE"

D_USER=$((USER - PREV_USER))
D_NICE=$((NICE - PREV_NICE))
D_SYSTEM=$((SYSTEM - PREV_SYSTEM))
D_IDLE=$((IDLE - PREV_IDLE))
D_IOWAIT=$((IOWAIT - PREV_IOWAIT))
D_IRQ=$((IRQ - PREV_IRQ))
D_SOFTIRQ=$((SOFTIRQ - PREV_SOFTIRQ))
D_STEAL=$((STEAL - PREV_STEAL))

TOTAL=$((D_USER + D_NICE + D_SYSTEM + D_IDLE + D_IOWAIT + D_IRQ + D_SOFTIRQ + D_STEAL))

if [ "$TOTAL" -le 0 ]; then
    echo "UNKNOWN - No CPU ticks elapsed since last check"
    exit 3
fi

PCT_USER=$((D_USER * 100 / TOTAL))
PCT_SYSTEM=$((D_SYSTEM * 100 / TOTAL))
PCT_IOWAIT=$((D_IOWAIT * 100 / TOTAL))
PCT_STEAL=$((D_STEAL * 100 / TOTAL))
PCT_IDLE=$((D_IDLE * 100 / TOTAL))
PCT_NICE=$((D_NICE * 100 / TOTAL))
PCT_IRQ=$(((D_IRQ + D_SOFTIRQ) * 100 / TOTAL))

PERFDATA="user=${PCT_USER}% system=${PCT_SYSTEM}% iowait=${PCT_IOWAIT}%;${IOWAIT_WARN};${IOWAIT_CRIT};0;100 steal=${PCT_STEAL}%;${STEAL_WARN};${STEAL_CRIT};0;100 idle=${PCT_IDLE}% nice=${PCT_NICE}% irq=${PCT_IRQ}%"

STATUS="user:${PCT_USER}% sys:${PCT_SYSTEM}% io:${PCT_IOWAIT}% steal:${PCT_STEAL}% idle:${PCT_IDLE}%"

if [ "$PCT_IOWAIT" -ge "$IOWAIT_CRIT" ] || [ "$PCT_STEAL" -ge "$STEAL_CRIT" ]; then
    echo "CRITICAL - CPU ${STATUS} | ${PERFDATA}"
    exit 2
elif [ "$PCT_IOWAIT" -ge "$IOWAIT_WARN" ] || [ "$PCT_STEAL" -ge "$STEAL_WARN" ]; then
    echo "WARNING - CPU ${STATUS} | ${PERFDATA}"
    exit 1
else
    echo "OK - CPU ${STATUS} | ${PERFDATA}"
    exit 0
fi
