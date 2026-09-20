#!/bin/bash
# Check for failed systemd units on the host.
#
# HISTORY. Until RT #1481 this check could not see the host at all. It runs
# inside the nagios-agent container, which had no /run/systemd and no system
# bus socket, so systemctl reported "Running in chroot, ignoring command" (as
# root, exit 0, empty output) or "System has not been booted with systemd as
# init system" (as nrpe, which is how NRPE runs it). The old implementation
# piped that straight into `grep -c "failed"`, got 0, and printed "OK - No
# failed systemd units" unconditionally. It had never once looked at the host.
#
# RT #1481 made it honest (UNKNOWN rather than a false OK). RT #1488 made it
# work: the unit now bind-mounts /run/systemd:ro AND the host system bus
# socket. Both are required -- /run/systemd alone still fails to connect to
# the bus. See the comment block in the .service file for the measurements.
#
# The honesty guards below are still load-bearing. They are what turns a
# future loss of host visibility into UNKNOWN instead of a silent green OK.

set -uo pipefail

OK=0; CRITICAL=2; UNKNOWN=3

err_file=$(mktemp) || { echo "SYSTEMD UNITS UNKNOWN - cannot create temp file"; exit $UNKNOWN; }
trap 'rm -f "$err_file"' EXIT

failed_out=$(systemctl --state=failed --no-legend --no-pager 2>"$err_file")
rc=$?
stderr=$(cat "$err_file")

if [ "$rc" -ne 0 ]; then
    echo "SYSTEMD UNITS UNKNOWN - systemctl exited ${rc}: ${stderr:-no error output}"
    exit $UNKNOWN
fi

# systemctl exits 0 while refusing to do anything when it thinks it is in a
# chroot, so a clean exit code is not on its own evidence that it looked.
if [ -n "$stderr" ]; then
    echo "SYSTEMD UNITS UNKNOWN - systemctl ran but did not query the host: ${stderr}"
    exit $UNKNOWN
fi

# Positive proof we reached a real system manager. Any of running, degraded,
# maintenance, starting, stopping is a live manager; offline/unknown is not.
state=$(systemctl is-system-running 2>/dev/null)
case "$state" in
    running|degraded|maintenance|starting|stopping) ;;
    *)
        echo "SYSTEMD UNITS UNKNOWN - no reachable system manager (is-system-running: ${state:-no answer})"
        exit $UNKNOWN
        ;;
esac

if [ -n "$failed_out" ]; then
    count=$(printf '%s\n' "$failed_out" | wc -l)
    # Failed units are printed with a leading bullet, but not under --plain and
    # not on every systemd version, so accept either shape.
    #
    # Do NOT match the bullet directly: it is multibyte (U+25CF, 3 bytes) and
    # this container runs with LANG unset / LC_CTYPE=POSIX, where gawk compares
    # bracket expressions bytewise. `$1 ~ /^[●*]$/` therefore never matches and
    # the alert names the bullet instead of the unit -- which is exactly what
    # RT #1488's canary caught. Key off the dot in the unit suffix instead: a
    # unit name always contains one, a bullet never does. Locale-proof.
    units=$(printf '%s\n' "$failed_out" | awk '{ print ($1 ~ /\./) ? $1 : $2 }' | tr '\n' ' ')
    echo "SYSTEMD UNITS CRITICAL - ${count} failed units: ${units}| failed=${count};1;;0"
    exit $CRITICAL
fi

echo "SYSTEMD UNITS OK - no failed systemd units | failed=0;1;;0"
exit $OK
