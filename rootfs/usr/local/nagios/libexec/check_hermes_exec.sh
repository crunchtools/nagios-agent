#!/bin/bash
# Run a Hermes probe inside the Hermes container and pass its verdict through.
#
# The evidence lives in Kagetora's data dir, which is 0700 and whose logs hold
# actual conversations. It never leaves its container: this sends the probe's
# source in over the podman exec socket and runs it there with the container's
# own python3, and only the one-line verdict comes back. The Hermes image has
# no grep, sed or awk, which is why the probes are standard-library Python.
# The source travels as one base64 line because podman_exec.sh builds its JSON
# without escaping newlines.
#
# This replaced hermes-probe.timer (2026-10-17), which ran the probes as root
# on the host every 60s and published a state file for NRPE to collect.
# Crunchtools schedules live in Hermes or Nagios, and Hermes cannot watch
# itself, so Nagios runs them.
#
# Fails CLOSED: an exec that cannot be created, or returns nothing, is
# CRITICAL, not UNKNOWN. A probe that dies must page, not go quiet; a
# monitoring chain that failed open is what let Kagetora sit deaf for three
# and a half days. A container that is not running fails the exec, so it
# pages here too.
#
# Usage: check_hermes_exec.sh <container> <probe.py> [probe args...]

set -u

EXEC=${PODMAN_EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
LIBEXEC=${LIBEXEC:-/usr/local/nagios/libexec}

if [ $# -lt 2 ]; then
    echo "CRITICAL - usage: check_hermes_exec.sh <container> <probe.py> [args...]"
    exit 2
fi
CONTAINER="$1"
NAME="$(basename "$2")"
PROBE="$LIBEXEC/$NAME"
shift 2

[ -r "$PROBE" ] || { echo "CRITICAL - probe $PROBE is missing"; exit 2; }
B64=$(base64 -w0 "$PROBE")
LOADER="import base64; exec(compile(base64.b64decode('$B64'), '$NAME', 'exec'))"

OUT=$("$EXEC" "$CONTAINER" python3 -c "$LOADER" "$@" 2>&1)
RC=$?

if [ -z "$OUT" ] || echo "$OUT" | grep -q "EXEC_ERROR"; then
    echo "CRITICAL - could not run $NAME in $CONTAINER (exit $RC): ${OUT:-no output}"
    exit 2
fi

# The probes turn their own exceptions into CRITICAL, but one that dies before
# that (a syntax error, a python3 that cannot start) exits 1 with a traceback,
# and exit 1 would otherwise read as WARNING.
if echo "$OUT" | grep -q "^Traceback (most recent call last)"; then
    echo "CRITICAL - $NAME crashed in $CONTAINER: $(echo "$OUT" | tail -1)"
    exit 2
fi

case "$RC" in
    0|1|2|3) echo "$OUT"; exit "$RC" ;;
    *) echo "CRITICAL - $NAME in $CONTAINER exited $RC: $OUT"; exit 2 ;;
esac
