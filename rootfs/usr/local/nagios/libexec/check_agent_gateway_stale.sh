#!/bin/bash
# An agent container whose gateway restarted after it started has lost its MCP
# client, silently, and will not get it back without a restart.
# Usage: check_agent_gateway_stale.sh <agent-container> [gateway-container] [grace_seconds]
#
# WHY THIS AND NOT A CONNECTION CHECK. The first version of this check counted
# ESTABLISHED connections from the agent to the gateway's client egress, on the
# theory that an agent holding none was unreachable. That is wrong: Claude
# Code's Remote Control POLLS -- a connection roughly every thirty to two
# hundred seconds, gone in about a second -- so a healthy idle agent has no
# connection at almost any instant. Measured on gloval 2026-11-06: one hit in
# ten samples over two minutes, against a container that was polling normally.
# The check reported CRITICAL for a healthy Josui Prime. (RT#1556)
#
# This watches the failure that is real, documented and silent: when the
# Trentina gateway restarts, every client's session dies with it. The gateway
# logs "client predates a gateway restart" and the agent carries on with no
# tools at all, looking perfectly healthy. Comparing two start times says so
# exactly, with no sampling and nothing to race against.
#
# NO EXEC, like the other container plugins: an API exec session leaves two
# conmon processes on the host for five minutes, which at a one-minute interval
# across the fleet is most of what "Host total processes" ends up counting.
#
# The grace exists so a deliberate restart sequence -- gateway first, then its
# agents, which is the correct order -- does not page while it is in progress.

AGENT="$1"
GATEWAY="${2:-trentina}"
GRACE="${3:-900}"

if [ -z "$AGENT" ]; then
    echo "UNKNOWN - Usage: $0 <agent-container> [gateway-container] [grace_seconds]"
    exit 3
fi

for name in "$AGENT" "$GATEWAY"; do
    if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        echo "UNKNOWN - invalid container name '$name'"
        exit 3
    fi
done
if ! [[ "$GRACE" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN - grace '$GRACE' is not a number of seconds"
    exit 3
fi

SOCK="/run/podman/podman.sock"

# Prints the container's start time as epoch seconds, or fails.
started_at() {
    local container=$1 raw rc iso
    raw=$(curl -sS --max-time 10 --unix-socket "$SOCK" \
        "http://localhost/v5.0.0/libpod/containers/${container}/json" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "curl exit ${rc}: ${raw}" >&2
        return 2
    fi
    if ! printf '%s' "$raw" | grep -q '"StartedAt"'; then
        printf '%s' "$raw" | grep -oP '"message"\s*:\s*"\K[^"]+' >&2
        return 1
    fi
    # Running is positive proof: a stopped container has a StartedAt too, and
    # judging a stopped agent on its old start time would read as healthy.
    if ! printf '%s' "$raw" | grep -qP '"Running"\s*:\s*true'; then
        echo "not running" >&2
        return 1
    fi
    iso=$(printf '%s' "$raw" | grep -oP '"StartedAt"\s*:\s*"\K[^"]+' | head -1)
    started_key "$iso" || { echo "unparseable StartedAt '$iso'" >&2; return 2; }
}

# A comparable NANOSECOND key for an RFC3339 stamp like
# 2026-11-06T01:01:13.120484139-05:00.
#
# Whole seconds are not enough: a gateway that restarts in the same second as
# the agent, but after it, would compare equal and read as healthy for ever.
# The fraction is taken from the string rather than from `date +%N`, which not
# every coreutils has -- the ubuntu-26.04 runners these tests run on ship
# uutils. And the stamps are NOT compared as strings: they carry a local UTC
# offset, so two containers either side of a daylight-saving change would
# order wrongly.
started_key() {
    local iso=$1 seconds fraction
    seconds=$(date -d "$iso" +%s 2>/dev/null) || return 1
    [[ "$seconds" =~ ^-?[0-9]+$ ]] || return 1
    fraction=0
    if [[ "$iso" =~ \.([0-9]+) ]]; then
        fraction=${BASH_REMATCH[1]}
        fraction=${fraction}000000000
        fraction=${fraction:0:9}
        fraction=$((10#$fraction))
    fi
    echo "$((seconds * 1000000000 + fraction))"
}

# A private file for the reason string, not a fixed /tmp path: two checks run
# at once on a busy agent, and a predictable name in a world-writable
# directory is both a race and a hazard.
ERR=$(mktemp) || { echo "UNKNOWN - cannot create a temporary file"; exit 3; }
trap 'rm -f "$ERR"' EXIT

AGENT_STARTED=$(started_at "$AGENT" 2>"$ERR")
case $? in
    0) ;;
    1) echo "CRITICAL - $AGENT: $(cat "$ERR")"; exit 2 ;;
    *) echo "UNKNOWN - $AGENT: $(cat "$ERR")"; exit 3 ;;
esac

if ! GATEWAY_STARTED=$(started_at "$GATEWAY" 2>"$ERR"); then
    # The gateway being down is its own check's business, not this one's.
    echo "UNKNOWN - $GATEWAY: $(cat "$ERR")"
    exit 3
fi

NOW=$(date +%s)
# Back to whole seconds for the message; the comparison above is the exact one.
BEHIND=$(( (GATEWAY_STARTED - AGENT_STARTED) / 1000000000 ))
GATEWAY_AGE=$(( NOW - GATEWAY_STARTED / 1000000000 ))
STALE=0
[ "$GATEWAY_STARTED" -gt "$AGENT_STARTED" ] && STALE=1
PERFDATA="seconds_behind=${BEHIND};0;0;; gateway_age=${GATEWAY_AGE}s"

if [ "$STALE" -eq 0 ]; then
    echo "OK - $AGENT started ${BEHIND#-}s after $GATEWAY, so its MCP client is current | $PERFDATA"
    exit 0
fi

if [ "$GATEWAY_AGE" -lt "$GRACE" ]; then
    echo "OK - $GATEWAY restarted ${GATEWAY_AGE}s ago, ${BEHIND}s after $AGENT started: inside the ${GRACE}s grace for a restart sequence | $PERFDATA"
    exit 0
fi

echo "CRITICAL - $GATEWAY restarted ${BEHIND}s after $AGENT started and has been up ${GATEWAY_AGE}s: $AGENT lost its MCP client and needs a restart to get it back | $PERFDATA"
exit 2
