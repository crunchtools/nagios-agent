#!/bin/bash
# check_container_restart.sh — alert on a container that restarted recently
# Usage: check_container_restart.sh <container-name> [crit_seconds] [warn_seconds]
#
# Detects the failure mode that hid RT #1459: a container dies, systemd's
# Restart=always brings it back within seconds, and every "is it running" check
# reports OK again before the next poll. The outage is real but leaves no state
# behind to alert on — only a gap in whatever the container was serving.
#
# Uptime is the signal. The units here run with --rm, so each restart produces a
# fresh container and RestartCount is always 0; State.StartedAt is the only
# field that moves. Keep crit_seconds >= the service's check_interval or a
# restart can land and age out between two consecutive polls.
#
# Reads the podman socket the container already exposes — no token, no bind
# mount of the target's data (constitution XVI).

NAME="$1"
CRIT_SECONDS="${2:-300}"
WARN_SECONDS="${3:-900}"
SOCK="/run/podman/podman.sock"

if [ -z "$NAME" ]; then
    echo "UNKNOWN - usage: check_container_restart.sh <container-name> [crit_seconds] [warn_seconds]"
    exit 3
fi

RAW=$(curl -s --unix-socket "$SOCK" "http://localhost/v5.0.0/containers/${NAME}/json" 2>/dev/null)

if [ -z "$RAW" ] || echo "$RAW" | grep -q '"cause"'; then
    echo "CRITICAL - Container $NAME not found"
    exit 2
fi

if ! echo "$RAW" | grep -q '"Running":true'; then
    STATE=$(echo "$RAW" | grep -o '"Status":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "CRITICAL - Container $NAME is ${STATE:-unknown}"
    exit 2
fi

STARTED=$(echo "$RAW" | grep -o '"StartedAt":"[^"]*"' | head -1 | cut -d'"' -f4)
STARTED_EPOCH=$(date -d "$STARTED" +%s 2>/dev/null)

if [ -z "$STARTED_EPOCH" ]; then
    echo "UNKNOWN - Container $NAME: unparseable StartedAt '$STARTED'"
    exit 3
fi

UPTIME=$(( $(date +%s) - STARTED_EPOCH ))
PERF="uptime=${UPTIME}s;${WARN_SECONDS};${CRIT_SECONDS}"

if [ "$UPTIME" -lt "$CRIT_SECONDS" ]; then
    echo "CRITICAL - Container $NAME restarted ${UPTIME}s ago | $PERF"
    exit 2
fi

if [ "$UPTIME" -lt "$WARN_SECONDS" ]; then
    echo "WARNING - Container $NAME restarted ${UPTIME}s ago | $PERF"
    exit 1
fi

printf 'OK - Container %s up %dd %dh %dm | %s\n' \
    "$NAME" $((UPTIME/86400)) $((UPTIME%86400/3600)) $((UPTIME%3600/60)) "$PERF"
exit 0
