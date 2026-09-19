#!/bin/bash
# Verify the central collector is still ingesting.
#
# This is the check that matters. A collector that has stopped reading the
# journal — a corrupt cursor, a revoked SELinux label, a wedged main queue —
# keeps its container "running" and its port open, so the container and TCP
# checks both stay green while every log on the box silently goes missing. The
# only honest signal is whether bytes are still landing on disk.
#
# Usage: check_syslog_freshness.sh [log_root] [warn_minutes] [crit_minutes]

LOG_ROOT="${1:-/srv/syslog.crunchtools.com/data/logs}"
WARN_MIN="${2:-10}"
CRIT_MIN="${3:-30}"

if [ ! -d "$LOG_ROOT" ]; then
    echo "CRITICAL - syslog log root $LOG_ROOT does not exist"
    exit 2
fi

# -path prune on _collector is load-bearing. That directory holds the collector's
# OWN impstats output, which it writes on a timer regardless of whether journal
# ingest is working. Counting it here would keep this check permanently green
# during exactly the outage it exists to detect.
newest=$(find "$LOG_ROOT" -path "$LOG_ROOT/_collector" -prune -o \
              -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
         | sort -rn | head -1)

if [ -z "$newest" ]; then
    echo "CRITICAL - no log files under $LOG_ROOT, collector has never written"
    exit 2
fi

mtime=${newest%% *}
path=${newest#* }
age_min=$(( ( $(date +%s) - ${mtime%.*} ) / 60 ))
sources=$(find "$LOG_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)

perf="age=${age_min}m;${WARN_MIN};${CRIT_MIN};0 sources=${sources}"
detail="newest ${path##*/logs/} is ${age_min}m old, ${sources} sources | $perf"

if [ "$age_min" -ge "$CRIT_MIN" ]; then
    echo "CRITICAL - syslog collector stalled: $detail"
    exit 2
elif [ "$age_min" -ge "$WARN_MIN" ]; then
    echo "WARNING - syslog collector quiet: $detail"
    exit 1
else
    echo "OK - syslog collector ingesting: $detail"
    exit 0
fi
