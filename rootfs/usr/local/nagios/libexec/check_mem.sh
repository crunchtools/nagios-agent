#!/bin/bash
# Check memory usage as a percentage (total - available) / total
# Usage: check_mem.sh -w <warn%> -c <crit%>

WARN=85
CRIT=95

while getopts "w:c:" opt; do
    case $opt in
        w) WARN=$OPTARG ;;
        c) CRIT=$OPTARG ;;
    esac
done

read -r TOTAL AVAIL <<< $(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t, a}' /proc/meminfo)

if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
    echo "UNKNOWN - Could not read /proc/meminfo"
    exit 3
fi

USED=$((TOTAL - AVAIL))
PCT=$((USED * 100 / TOTAL))
TOTAL_MB=$((TOTAL / 1024))
USED_MB=$((USED / 1024))
AVAIL_MB=$((AVAIL / 1024))

PERFDATA="mem_used=${USED_MB}MB;$((TOTAL_MB * WARN / 100));$((TOTAL_MB * CRIT / 100));0;${TOTAL_MB}"

if [ "$PCT" -ge "$CRIT" ]; then
    echo "CRITICAL - Memory ${PCT}% used [${USED_MB}MB/${TOTAL_MB}MB] | ${PERFDATA}"
    exit 2
elif [ "$PCT" -ge "$WARN" ]; then
    echo "WARNING - Memory ${PCT}% used [${USED_MB}MB/${TOTAL_MB}MB] | ${PERFDATA}"
    exit 1
else
    echo "OK - Memory ${PCT}% used [${USED_MB}MB/${TOTAL_MB}MB] | ${PERFDATA}"
    exit 0
fi
