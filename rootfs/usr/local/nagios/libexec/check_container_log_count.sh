#!/bin/bash
# Count the lines of a container's log that contain a fixed string within the
# last WINDOW seconds (a953).
#
# Written for Trentina's L3: an OpenRouter key at its spending limit answers
# every judge call with 403, and Trentina logs each one as
# "QuarantineAgentError status=403". A handful is noise; a steady stream means
# a profile has lost L3. check_openrouter_key.sh warns before the limit; this
# is the backstop that sees the outage itself, whatever caused the 403.
#
# Reads the log through the podman socket, streamed into grep, so a burst of
# log lines costs no memory.
#
#   OK        WARN lines or fewer
#   WARNING   more than WARN
#   CRITICAL  more than CRIT
#   UNKNOWN   the container or its log could not be read
#
# Usage: check_container_log_count.sh <container> <window-secs> <warn> <crit> <label> <string>
#   check_container_log_count.sh trentina 600 5 20 "L3 403s" "QuarantineAgentError status=403"

SOCK="${PODMAN_SOCK:-/run/podman/podman.sock}"
API="http://localhost/v5.0.0"
CONTAINER="${1:-}"
WINDOW="${2:-}"
WARN="${3:-}"
CRIT="${4:-}"
LABEL="${5:-}"
STRING="${6:-}"

unknown() { echo "LOG COUNT UNKNOWN - $1"; exit 3; }

[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || unknown "invalid container name"
[[ "$WINDOW" =~ ^[1-9][0-9]*$ && "$WARN" =~ ^[0-9]+$ && "$CRIT" =~ ^[0-9]+$ ]] \
    || unknown "window, warn and crit must be whole numbers"
[ "$WARN" -le "$CRIT" ] || unknown "warning threshold above critical"
[ -n "$LABEL" ] && [ -n "$STRING" ] || unknown "label and string are required"

SINCE=$(( $(date +%s) - WINDOW ))
# -f: a missing container is a 404, which must not read as zero lines.
# PIPESTATUS has to be read inside the substitution: outside it, it describes
# the assignment. grep -c exits 1 on no match, so pipefail would not do.
# -d "": the count and the status arrive on two lines.
read -r -d "" COUNT CURL_RC <<<"$(curl -sf --max-time 30 --unix-socket "$SOCK" \
    "$API/containers/${CONTAINER}/logs?stdout=true&stderr=true&since=${SINCE}" \
    | grep -acF -- "$STRING"; echo "${PIPESTATUS[0]}")"
[ "$CURL_RC" -eq 0 ] || unknown "$LABEL: cannot read the log of $CONTAINER (curl rc=$CURL_RC)"
[[ "$COUNT" =~ ^[0-9]+$ ]] || unknown "$LABEL: no count"

MINS=$(( (WINDOW + 59) / 60 ))
PERF="lines=${COUNT};${WARN};${CRIT};0"
if [ "$COUNT" -gt "$CRIT" ]; then
    echo "LOG COUNT CRITICAL - $LABEL: $COUNT in ${MINS}m in $CONTAINER (over $CRIT) | $PERF"; exit 2
elif [ "$COUNT" -gt "$WARN" ]; then
    echo "LOG COUNT WARNING - $LABEL: $COUNT in ${MINS}m in $CONTAINER (over $WARN) | $PERF"; exit 1
fi
echo "LOG COUNT OK - $LABEL: $COUNT in ${MINS}m in $CONTAINER | $PERF"
exit 0
