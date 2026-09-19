#!/bin/bash
# Check for failed systemd units on the host.
#
# WARNING: as of RT #1481 this check cannot actually see the host. It runs
# inside the nagios-agent container, which has no /run/systemd and no system
# bus socket, so systemctl either reports "Running in chroot, ignoring
# command" (as root, exit 0, empty output) or "System has not been booted with
# systemd as init system" (as nrpe, which is how NRPE runs it). The host had
# 529 units at the time of writing; the container saw none of them.
#
# The old implementation piped that straight into `grep -c "failed"`, got 0,
# and printed "OK - No failed systemd units" unconditionally. It had never
# once looked at the host. Same fail-open shape as check_quay_pull_source.sh:
# stderr discarded, every failure mode collapsing into the success branch.
#
# This version cannot fix the visibility problem -- that needs a host bus
# socket or an nsenter privilege split, tracked separately -- but it refuses
# to lie about it. UNKNOWN is honest; OK was not.

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
    units=$(printf '%s\n' "$failed_out" | awk '{ if ($1 ~ /^[●*]$/) print $2; else print $1 }' | tr '\n' ' ')
    echo "SYSTEMD UNITS CRITICAL - ${count} failed units: ${units}| failed=${count};1;;0"
    exit $CRITICAL
fi

echo "SYSTEMD UNITS OK - no failed systemd units | failed=0;1;;0"
exit $OK
