#!/bin/bash
# Check PostgreSQL health inside a container via pg_isready + connection count
# Uses the standard pg_isready protocol check (not just TCP)
# Usage: check_container_postgres.sh <container> [warn_conns] [crit_conns] [port]

CONTAINER="$1"
WARN_CONNS="${2:-30}"
CRIT_CONNS="${3:-50}"
PORT="${4:-5432}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn_conns] [crit_conns] [port]"
    exit 3
fi

READY=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" pg_isready -h localhost -p "$PORT" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    echo "CRITICAL - PostgreSQL in $CONTAINER not accepting connections: $READY"
    exit 2
fi

CONNS=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" psql -U postgres -h localhost -p "$PORT" -t -A \
    -c "SELECT count(*) FROM pg_stat_activity WHERE state IS NOT NULL" 2>/dev/null)

if [ -z "$CONNS" ]; then
    echo "OK - PostgreSQL in $CONTAINER accepting connections (could not query stats) | connections=0;${WARN_CONNS};${CRIT_CONNS};0;"
    exit 0
fi

PERFDATA="connections=${CONNS};${WARN_CONNS};${CRIT_CONNS};0;"

if [ "$CONNS" -ge "$CRIT_CONNS" ]; then
    echo "CRITICAL - PostgreSQL in $CONTAINER: ${CONNS} active connections | $PERFDATA"
    exit 2
elif [ "$CONNS" -ge "$WARN_CONNS" ]; then
    echo "WARNING - PostgreSQL in $CONTAINER: ${CONNS} active connections | $PERFDATA"
    exit 1
else
    echo "OK - PostgreSQL in $CONTAINER: ${CONNS} active connections | $PERFDATA"
    exit 0
fi
