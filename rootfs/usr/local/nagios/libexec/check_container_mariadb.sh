#!/bin/bash
# Check MariaDB health inside a container via mysqladmin status
# Standard approach from check_mysql_health pattern — connection test + thread count
# Usage: check_container_mariadb.sh <container> [warn_threads] [crit_threads]

CONTAINER="$1"
WARN_THREADS="${2:-20}"
CRIT_THREADS="${3:-50}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn_threads] [crit_threads]"
    exit 3
fi

STATUS=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" mysqladmin -u root status 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    echo "CRITICAL - MariaDB in $CONTAINER not responding: $STATUS"
    exit 2
fi

UPTIME=$(echo "$STATUS" | grep -oP 'Uptime:\s+\K\d+')
THREADS=$(echo "$STATUS" | grep -oP 'Threads:\s+\K\d+')
QUERIES=$(echo "$STATUS" | grep -oP 'Questions:\s+\K\d+')
SLOW=$(echo "$STATUS" | grep -oP 'Slow queries:\s+\K\d+')

PERFDATA="threads=${THREADS:-0};${WARN_THREADS};${CRIT_THREADS};0; uptime=${UPTIME:-0};;;0; queries=${QUERIES:-0};;;0; slow_queries=${SLOW:-0};;;0;"

if [ "${THREADS:-0}" -ge "$CRIT_THREADS" ]; then
    echo "CRITICAL - MariaDB in $CONTAINER: ${THREADS} threads, uptime ${UPTIME}s | $PERFDATA"
    exit 2
elif [ "${THREADS:-0}" -ge "$WARN_THREADS" ]; then
    echo "WARNING - MariaDB in $CONTAINER: ${THREADS} threads, uptime ${UPTIME}s | $PERFDATA"
    exit 1
else
    echo "OK - MariaDB in $CONTAINER: ${THREADS} threads, uptime ${UPTIME}s, ${SLOW} slow queries | $PERFDATA"
    exit 0
fi
