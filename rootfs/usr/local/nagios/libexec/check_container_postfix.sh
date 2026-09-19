#!/bin/bash
# Check Postfix health inside a container via mailq
# Standard approach from check_mailq pattern — queue size monitoring
# Usage: check_container_postfix.sh <container> [warn_queue] [crit_queue]

CONTAINER="$1"
WARN_QUEUE="${2:-20}"
CRIT_QUEUE="${3:-100}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn_queue] [crit_queue]"
    exit 3
fi

MAILQ=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" mailq 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    echo "CRITICAL - Postfix in $CONTAINER: mailq failed: $MAILQ"
    exit 2
fi

if echo "$MAILQ" | grep -q "Mail queue is empty"; then
    QUEUE_SIZE=0
else
    QUEUE_SIZE=$(echo "$MAILQ" | grep -c '^[A-F0-9]')
fi

DEFERRED=$(echo "$MAILQ" | grep -c '(deferred')

PERFDATA="queue_size=${QUEUE_SIZE};${WARN_QUEUE};${CRIT_QUEUE};0; deferred=${DEFERRED};;;0;"

if [ "$QUEUE_SIZE" -ge "$CRIT_QUEUE" ]; then
    echo "CRITICAL - Postfix in $CONTAINER: ${QUEUE_SIZE} queued, ${DEFERRED} deferred | $PERFDATA"
    exit 2
elif [ "$QUEUE_SIZE" -ge "$WARN_QUEUE" ]; then
    echo "WARNING - Postfix in $CONTAINER: ${QUEUE_SIZE} queued, ${DEFERRED} deferred | $PERFDATA"
    exit 1
else
    echo "OK - Postfix in $CONTAINER: ${QUEUE_SIZE} queued, ${DEFERRED} deferred | $PERFDATA"
    exit 0
fi
