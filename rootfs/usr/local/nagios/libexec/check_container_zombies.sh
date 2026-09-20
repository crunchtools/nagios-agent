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
# HARDENED-IMAGE FIX (RT #1493). podman_exec.sh's ps-inside-the-container
# approach assumes the target ships procps. Minimal/distroless images
# (mcp-ashigaru and friends) do not -- ps exits 127, "command not found",
# reported as UNKNOWN by the fix above. Fine for detection, useless for
# actually checking those containers, which is most of the hardened fleet.
#
# Fix: use the podman Engine API's /containers/{id}/top endpoint instead of
# exec. It runs `ps` on the HOST against the container's PIDs through the
# kernel's PID namespace, the same way `podman top` does from the CLI -- no
# binary of any kind needs to exist inside the target. Requesting exactly
# pid,stat,comm keeps the response a fixed 3-column shape so it can be
# parsed without jq (not installed in this image; podman_exec.sh sets the
# same no-jq precedent as PODMAN's REST responses are otherwise verbose).

CONTAINER="$1"
WARN="${2:-1}"
CRIT="${3:-5}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn] [crit]"
    exit 3
fi

SOCK="/run/podman/podman.sock"

RAW=$(curl -s --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/containers/${CONTAINER}/top?ps_args=-eo%20pid%2Cstat%2Ccomm" 2>&1)
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "UNKNOWN - $CONTAINER: podman top request failed (curl exit ${RC})"
    exit 3
fi

# Positive proof we got a real process table, not an error body. Podman
# returns {"cause":...,"message":...} on failure (stopped/renamed/unreachable
# container) with no Titles key -- that must not be read as zero processes.
if ! printf '%s' "$RAW" | grep -q '"Titles"'; then
    ERRMSG=$(printf '%s' "$RAW" | grep -oP '"message"\s*:\s*"\K[^"]+')
    echo "UNKNOWN - $CONTAINER: podman top failed${ERRMSG:+: $ERRMSG}"
    exit 3
fi

PROC_ROWS=$(printf '%s' "$RAW" | grep -oP '"Processes":\[\K.*(?=\],"Titles")' | grep -oP '\[[^]]*\]')

if [ -z "$PROC_ROWS" ]; then
    echo "UNKNOWN - $CONTAINER: podman top returned no process rows"
    exit 3
fi

TOTAL=0
ZOMBIES=0
while IFS= read -r row; do
    TOTAL=$((TOTAL + 1))
    STAT=$(printf '%s' "$row" | sed -E 's/^\["[^"]*","([^"]*)".*/\1/')
    case "$STAT" in
        Z*) ZOMBIES=$((ZOMBIES + 1)) ;;
    esac
done <<< "$PROC_ROWS"

# PID 1 always shows up for a running container. Zero rows despite a
# well-formed response means the parse broke, not that the table is empty.
if [ "$TOTAL" -eq 0 ]; then
    echo "UNKNOWN - $CONTAINER: parsed zero processes from podman top"
    exit 3
fi

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
