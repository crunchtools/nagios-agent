#!/bin/bash
# check_service_running.sh — a long-running service that restarts itself
# Usage: check_service_running.sh <service-unit>
#
# For a unit with Restart=always, a broken service never reaches "failed": it
# loops between auto-restart and activating, and check_systemd_units.sh (which
# looks only for failed units) stays green. The GitHub Actions runners on
# gloval are the case that needed this: a runner whose podman could not start
# looped every five seconds and nothing paged. So:
#
#   active (running)                -> OK
#   activating / reloading          -> WARNING (starting; retries absorb it)
#   auto-restart, failed, inactive  -> CRITICAL
#
# A one-job runner restarts between jobs by design, so a single WARNING or
# CRITICAL here is expected now and then; the Nagios service definition's
# retries are what separate that from a loop. NRestarts is in the output so a
# loop is visible at a glance.
#
# Needs the host's systemd (fast pool), with the same guard as
# check_systemd_units.sh: a systemctl that cannot see the host is UNKNOWN.
set -uo pipefail

UNIT="${1:-}"
if [ -z "$UNIT" ]; then
    echo "UNKNOWN - usage: check_service_running.sh <service-unit>"
    exit 3
fi
if ! [[ "$UNIT" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*\.service$ ]]; then
    echo "UNKNOWN - invalid unit name"
    exit 3
fi

state=$(systemctl is-system-running 2>/dev/null)
case "$state" in
    running|degraded|maintenance|starting|stopping) ;;
    *)
        echo "UNKNOWN - no reachable system manager (is-system-running: ${state:-no answer})"
        exit 3
        ;;
esac

props=$(systemctl show -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestamp "$UNIT" 2>/dev/null) || {
    echo "UNKNOWN - cannot read state of $UNIT"
    exit 3
}
get() { printf '%s\n' "$props" | sed -n "s/^$1=//p"; }
active=$(get ActiveState); sub=$(get SubState); restarts=$(get NRestarts); since=$(get ActiveEnterTimestamp)
[ -n "$active" ] || { echo "UNKNOWN - cannot read state of $UNIT"; exit 3; }
restarts=${restarts:-0}
perf="| restarts=$restarts"

case "$active/$sub" in
    active/running)
        echo "OK - $UNIT running since ${since:-unknown}, $restarts restarts $perf"; exit 0 ;;
    activating/auto-restart|failed/*|inactive/*)
        echo "CRITICAL - $UNIT is $active ($sub), $restarts restarts $perf"; exit 2 ;;
    *)
        echo "WARNING - $UNIT is $active ($sub), $restarts restarts $perf"; exit 1 ;;
esac
