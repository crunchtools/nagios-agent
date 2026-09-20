#!/bin/bash
# Check for zombie processes inside a container
# Usage: check_container_zombies.sh <container> [warn] [crit]
#
# FAIL-OPEN FIX (RT #1488 sweep). The old body was:
#
#   ZOMBIES=$(podman_exec.sh "$CONTAINER" ps aux 2>/dev/null | grep -c '[d]efunct')
#
# Exactly the shape that made check_systemd_units lie for months: stderr to
# /dev/null, and `grep -c` over empty input returns 0, which lands in the OK
# branch. A container that was stopped, renamed, or unreachable through the
# podman socket reported "no zombie processes" -- a clean bill of health for
# something the check could not see at all.
#
# Now: check the exit status, and require the output to actually look like ps
# output before trusting a zero count. Cannot see it -> UNKNOWN, not OK.

CONTAINER="$1"
WARN="${2:-1}"
CRIT="${3:-5}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn] [crit]"
    exit 3
fi

err_file=$(mktemp) || { echo "UNKNOWN - cannot create temp file"; exit 3; }
trap 'rm -f "$err_file"' EXIT

PS_OUT=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" ps aux 2>"$err_file")
RC=$?
STDERR=$(cat "$err_file")

if [ "$RC" -ne 0 ]; then
    echo "UNKNOWN - $CONTAINER: ps failed (exit ${RC}): ${STDERR:-no error output}"
    exit 3
fi

# Positive proof we got real ps output. An empty or header-less body means we
# never saw the process table, which is not the same as an empty process table.
if ! printf '%s\n' "$PS_OUT" | grep -qE '^(USER|UID)[[:space:]]+PID'; then
    echo "UNKNOWN - $CONTAINER: ps produced no process table${STDERR:+: $STDERR}"
    exit 3
fi

ZOMBIES=$(printf '%s\n' "$PS_OUT" | grep -c '[d]efunct')

PERFDATA="zombies=${ZOMBIES};${WARN};${CRIT};0;"

if [ "$ZOMBIES" -ge "$CRIT" ]; then
    echo "CRITICAL - $CONTAINER: ${ZOMBIES} zombie processes | $PERFDATA"
    exit 2
elif [ "$ZOMBIES" -ge "$WARN" ]; then
    echo "WARNING - $CONTAINER: ${ZOMBIES} zombie processes | $PERFDATA"
    exit 1
else
    echo "OK - $CONTAINER: no zombie processes | $PERFDATA"
    exit 0
fi
