#!/bin/bash
# Collect the Hermes platform verdict published by hermes-probe.timer.
#
# This half runs as the unprivileged nrpe user and deliberately knows nothing
# about Hermes. It only enforces one rule the rest of the chain cannot enforce
# for itself: the verdict must be RECENT. A verdict file that stopped being
# updated is not good news, it is the absence of news, and this check is the
# one place that distinguishes the two.
#
# Usage: check_hermes_probe.sh [state_file] [max_age_s]

set -u

STATE="${1:-/run/hermes-probe/kagetora.state}"
MAX_AGE="${2:-300}"

if [ ! -r "$STATE" ]; then
    echo "CRITICAL - Hermes probe has published nothing at $STATE (is hermes-probe.timer running?)"
    exit 2
fi

PROBED_AT=$(sed -n 's/^probed_at=//p' "$STATE" | head -1)
STATUS=$(sed -n 's/^status=//p' "$STATE" | head -1)
TEXT=$(sed -n 's/^text=//p' "$STATE" | head -1)

case "${PROBED_AT:-}" in
    ''|*[!0-9]*) echo "CRITICAL - Hermes probe state file is malformed (no probed_at)"; exit 2 ;;
esac

AGE=$(( $(date +%s) - PROBED_AT ))
[ "$AGE" -lt 0 ] && AGE=0

if [ "$AGE" -gt "$MAX_AGE" ]; then
    echo "CRITICAL - Hermes probe verdict is ${AGE}s old (max ${MAX_AGE}s); the probe has stopped running, so platform health is UNKNOWN | probe_age=${AGE}s;;${MAX_AGE};0"
    exit 2
fi

case "${STATUS:-}" in
    0|1|2|3) ;;
    *) echo "CRITICAL - Hermes probe state file is malformed (status='${STATUS:-}')"; exit 2 ;;
esac

# Splice the freshness note into the message half and merge perfdata, rather
# than appending after the pipe where Nagios would parse it as a broken metric.
MSG="${TEXT%%|*}"
PERF="${TEXT#*|}"
[ "$PERF" = "$TEXT" ] && PERF=""

MSG=$(echo "${MSG:-no text published}" | sed 's/[[:space:]]*$//')
echo "$MSG (probed ${AGE}s ago) |${PERF} probe_age=${AGE}s;;${MAX_AGE};0"
exit "$STATUS"
