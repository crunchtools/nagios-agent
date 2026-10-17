#!/bin/bash
# check_ondemand_unit.sh — health of a service that runs only on demand
# Usage: check_ondemand_unit.sh <socket-unit> <service-unit> [path-unit]
#
# For a container started by a socket (and optionally a path unit) and stopped
# when idle, "not running" is the normal state, so check_container_running.sh
# would page every idle hour. What can actually break is the door: if the
# socket or path unit is down, nothing will ever start the service again, and
# nobody notices until they need it. So:
#
#   socket or path unit not active  -> CRITICAL (nothing will start it)
#   service failed                  -> CRITICAL
#   service active or activating    -> OK
#   service inactive                -> OK, idle
#
# Needs the host's systemd, which only the fast pool has (/run/systemd + the
# system bus). The guard below is the one check_systemd_units.sh uses: a
# systemctl that cannot see the host must say UNKNOWN, not "idle".

set -uo pipefail

SOCKET="${1:-}"
SERVICE="${2:-}"
PATHU="${3:-}"

if [ -z "$SOCKET" ] || [ -z "$SERVICE" ]; then
    echo "UNKNOWN - usage: check_ondemand_unit.sh <socket-unit> <service-unit> [path-unit]"
    exit 3
fi
for u in "$SOCKET" "$SERVICE" ${PATHU:+"$PATHU"}; do
    if ! [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*\.(socket|service|path)$ ]]; then
        echo "UNKNOWN - invalid unit name"
        exit 3
    fi
done

state=$(systemctl is-system-running 2>/dev/null)
case "$state" in
    running|degraded|maintenance|starting|stopping) ;;
    *)
        echo "UNKNOWN - no reachable system manager (is-system-running: ${state:-no answer})"
        exit 3
        ;;
esac

active_state() {
    local out
    out=$(systemctl show -p ActiveState --value "$1" 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    echo "$out"
}

for u in "$SOCKET" ${PATHU:+"$PATHU"}; do
    s=$(active_state "$u") || { echo "UNKNOWN - cannot read state of $u"; exit 3; }
    if [ "$s" != active ]; then
        echo "CRITICAL - $u is $s: nothing will start $SERVICE"
        exit 2
    fi
done

svc=$(active_state "$SERVICE") || { echo "UNKNOWN - cannot read state of $SERVICE"; exit 3; }
case "$svc" in
    failed)
        echo "CRITICAL - $SERVICE failed"
        exit 2
        ;;
    active)
        since=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null)
        echo "OK - $SERVICE running${since:+ since $since}"
        exit 0
        ;;
    activating|reloading)
        echo "OK - $SERVICE starting"
        exit 0
        ;;
    inactive|deactivating)
        echo "OK - $SERVICE idle, starts on demand"
        exit 0
        ;;
    *)
        echo "WARNING - $SERVICE is $svc"
        exit 1
        ;;
esac
