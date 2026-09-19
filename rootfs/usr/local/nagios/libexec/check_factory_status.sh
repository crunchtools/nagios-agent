#!/bin/bash
# check_factory_status.sh — report the factory watchdog's own verdict to Nagios
# Usage: check_factory_status.sh <status-file> <max_age_min> <warn_failing> <crit_failing>
#
# The watchdog evaluates every repo in the org each hour and writes its findings
# to factory-status.json. Until RT #1478 the only thing it did with them was
# push 8 trapper items to a Zabbix server that had been decommissioned, so every
# verdict went to a dead socket and nobody learned that repos were failing.
#
# Reads the file straight off the host — the factory container bind-mounts the
# same directory, so there is no credential, no podman exec and no HTTP call
# between this check and the truth (constitution XVI). It deliberately does NOT
# go through the dashboard's /api/status: the dashboard is a separate process
# that can be down while the findings on disk are perfectly good, and a check
# should not inherit a dependency it does not need.
#
# STALENESS IS THE CRITICAL CASE. A watchdog that stopped running leaves a file
# full of reassuring numbers, and reading it without checking its age is how a
# monitoring system reports OK about a job that died days ago.

STATUS_FILE="${1:-/srv/factory.crunchtools.com/data/factory-status.json}"
MAX_AGE_MIN="${2:-120}"
WARN_FAILING="${3:-1}"
CRIT_FAILING="${4:-30}"

if [ ! -r "$STATUS_FILE" ]; then
    echo "UNKNOWN - cannot read $STATUS_FILE"
    exit 3
fi

field() {
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9]+" "$STATUS_FILE" \
        | head -1 | grep -oE '[0-9]+$'
}

TOTAL=$(field repos_total)
FAILING=$(field repos_failing)
GHA=$(field gha_failing)
CONST=$(field constitution_failing)

if [ -z "$TOTAL" ] || [ -z "$FAILING" ]; then
    echo "UNKNOWN - $STATUS_FILE has no summary block (watchdog schema changed?)"
    exit 3
fi

AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$STATUS_FILE") ) / 60 ))
HEALTHY=$(( TOTAL - FAILING ))
PERF="repos_failing=$FAILING;$WARN_FAILING;$CRIT_FAILING;0;$TOTAL gha_failing=${GHA:-0} constitution_failing=${CONST:-0} age_min=${AGE_MIN};${MAX_AGE_MIN}"

if [ "$AGE_MIN" -ge "$MAX_AGE_MIN" ]; then
    echo "CRITICAL - factory status is ${AGE_MIN}m old (max ${MAX_AGE_MIN}m) - watchdog has stopped writing | $PERF"
    exit 2
fi

SUMMARY="$HEALTHY/$TOTAL repos healthy, ${GHA:-0} GHA failing, ${CONST:-0} constitution failing (${AGE_MIN}m old)"

if [ "$FAILING" -ge "$CRIT_FAILING" ]; then
    echo "CRITICAL - $FAILING repos failing - $SUMMARY | $PERF"
    exit 2
fi

if [ "$FAILING" -ge "$WARN_FAILING" ]; then
    echo "WARNING - $FAILING repos failing - $SUMMARY | $PERF"
    exit 1
fi

echo "OK - $SUMMARY | $PERF"
exit 0
