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
# Uptime alone cannot tell a crash from a deploy, and deploys were nearly every
# page. Inside the crit window the podman events log says why the previous
# container ended: its "die" event outlives --rm. An OOM kill, an exit other
# than 0 or 143 (SIGTERM from systemctl stop/restart), or more than LOOP_MAX
# deaths in the hour before this start is CRITICAL. A clean stop is OK. If the
# events cannot be read, the restart stays CRITICAL; an unexplained restart is
# never quiet.
#
# Reads the podman socket the container already exposes — no token, no bind
# mount of the target's data (constitution XVI).

NAME="$1"
CRIT_SECONDS="${2:-300}"
WARN_SECONDS="${3:-0}"
LOOP_MAX=3
SOCK="/run/podman/podman.sock"

if [ -z "$NAME" ]; then
    echo "UNKNOWN - usage: check_container_restart.sh <container-name> [crit_seconds] [warn_seconds]"
    exit 3
fi

if ! [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "UNKNOWN - invalid container name"
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

NOW=$(date +%s)
UPTIME=$(( NOW - STARTED_EPOCH ))
PERF="uptime=${UPTIME}s;${WARN_SECONDS};${CRIT_SECONDS}"

if [ "$UPTIME" -lt "$CRIT_SECONDS" ]; then
    EVENTS=$(curl -s --max-time 10 --unix-socket "$SOCK" -G "http://localhost/v5.0.0/events" \
        --data-urlencode stream=false \
        --data-urlencode "since=$((STARTED_EPOCH - 3600))" --data-urlencode "until=$NOW" \
        --data-urlencode "filters={\"container\":[\"$NAME\"],\"event\":[\"died\",\"oom\"]}" 2>/dev/null)
    CURL_RC=$?
    # One pass, no forks. The newest death by timeNano is the container this
    # one replaced.
    DIES=0 OOMS=0 LAST_T=-1 LAST_CODE="?"
    while IFS= read -r ev; do
        case "$ev" in
            *'"status":"oom"'*) OOMS=$((OOMS + 1)) ;;
            *'"status":"die"'*)
                DIES=$((DIES + 1))
                t=0 c="?"
                [[ "$ev" =~ \"timeNano\":([0-9]+) ]] && t="${BASH_REMATCH[1]}"
                [[ "$ev" =~ \"containerExitCode\":\"([0-9]+)\" ]] && c="${BASH_REMATCH[1]}"
                if [ "$t" -gt "$LAST_T" ]; then LAST_T="$t" LAST_CODE="$c"; fi ;;
        esac
    done <<< "$EVENTS"

    if [ "$CURL_RC" -ne 0 ] || [ "$DIES" -eq 0 ]; then
        echo "CRITICAL - Container $NAME restarted ${UPTIME}s ago, cause unknown (no die event readable) | $PERF"
        exit 2
    fi
    if [ "$OOMS" -gt 0 ]; then
        echo "CRITICAL - Container $NAME OOM-killed, restarted ${UPTIME}s ago | $PERF"
        exit 2
    fi
    if [ "$DIES" -gt "$LOOP_MAX" ]; then
        echo "CRITICAL - Container $NAME restart loop: $DIES deaths in the hour before this start | $PERF"
        exit 2
    fi
    if [ "$LAST_CODE" != 0 ] && [ "$LAST_CODE" != 143 ]; then
        echo "CRITICAL - Container $NAME exited $LAST_CODE, restarted ${UPTIME}s ago | $PERF"
        exit 2
    fi
    echo "OK - Container $NAME restarted ${UPTIME}s ago, clean stop (exit $LAST_CODE) | $PERF"
    exit 0
fi

if [ "$UPTIME" -lt "$WARN_SECONDS" ]; then
    echo "WARNING - Container $NAME restarted ${UPTIME}s ago | $PERF"
    exit 1
fi

printf 'OK - Container %s up %dd %dh %dm | %s\n' \
    "$NAME" $((UPTIME/86400)) $((UPTIME%86400/3600)) $((UPTIME%3600/60)) "$PERF"
exit 0
