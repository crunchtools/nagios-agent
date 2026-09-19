#!/bin/bash
# Watch how much disk the collected logs occupy.
#
# Centralising 40+ containers' output onto one filesystem makes /var the new
# shared fate: a chatty container in a crash loop can fill it and take the whole
# host down with it. The retention timer is the control; this is the alarm for
# when retention is not keeping up.
#
# Usage: check_syslog_disk.sh [log_root] [warn_gb] [crit_gb]

LOG_ROOT="${1:-/srv/syslog.crunchtools.com/data/logs}"
WARN_GB="${2:-10}"
CRIT_GB="${3:-20}"

if [ ! -d "$LOG_ROOT" ]; then
    echo "CRITICAL - syslog log root $LOG_ROOT does not exist"
    exit 2
fi

used_mb=$(du -sm "$LOG_ROOT" 2>/dev/null | cut -f1)
used_gb=$(( used_mb / 1024 ))

# Name the loudest source, so the alert says what to go look at.
top=$(du -sm "$LOG_ROOT"/*/ 2>/dev/null | sort -rn | head -1)
top_mb=${top%%	*}
top_name=$(basename "${top#*	}" 2>/dev/null)

perf="used=${used_mb}MB;$((WARN_GB * 1024));$((CRIT_GB * 1024));0"
detail="${used_gb}GB used, largest source ${top_name:-none} at ${top_mb:-0}MB | $perf"

if [ "$used_gb" -ge "$CRIT_GB" ]; then
    echo "CRITICAL - syslog storage: $detail"
    exit 2
elif [ "$used_gb" -ge "$WARN_GB" ]; then
    echo "WARNING - syslog storage: $detail"
    exit 1
else
    echo "OK - syslog storage: $detail"
    exit 0
fi
