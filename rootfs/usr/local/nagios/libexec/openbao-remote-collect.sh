#!/bin/bash
# openbao-remote-collect.sh — read agentless hosts' OpenBao health markers off the NRPE hot path
#
# WHY. Exedore runs its own OpenBao (a256) and has no NRPE agent, so gloval's
# check_openbao cannot reach it. A timer there (crunchtools/openbao
# deploy/exedore/openbao-health-push) copies one line to
# pcloud:Monitoring/OpenBao/<host> every 10 minutes: the route Cold Copy
# Freshness and Skills Sync already take.
#
# WHO RUNS THIS. check_openbao_remote.sh starts it detached through
# `podman_exec.sh --detach` into nagios-agent.crunchtools.com whenever the
# status file is older than its REFRESH or missing, and judges the file the
# previous run wrote -- the collector pattern in skills-sync-collect.sh.
#
# WHAT IT WRITES. $STATE_DIR/openbao-remote.status, replaced atomically:
#
#   OBHEALTH generated=<epoch> seen=<epoch> rc=<rclone exit> [lastfail=<why>]
#   OBHEALTH marker=OPENBAOHEALTH host=<h> written=<epoch> http=<code> initialized=<b> sealed=<b> snapshot=<epoch>
#   OBHEALTH end=1
#
# A read that fails keeps the previous run's markers and their seen; the plugin
# turns a seen older than its STALE into UNKNOWN. Only marker lines that are
# plain key=value words survive into the file.
set -uo pipefail
# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3
RCLONE=${RCLONE:-/usr/local/bin/rclone}
CONF=${CONF:-/etc/nagios/rclone.conf}
REMOTE=${REMOTE:-pcloud:Monitoring/OpenBao}
READ_T=${READ_T:-60}
STATUS="$STATE_DIR/openbao-remote.status"

cl_lock openbao-remote   # exits 0 when a run is already in progress
[ -x "$RCLONE" ] || { echo "$RCLONE not mounted into agent container" >&2; exit 3; }
[ -r "$CONF" ]   || { echo "$CONF not readable" >&2; exit 3; }

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

markers=$(timeout "$READ_T" "$RCLONE" --config "$CONF" cat "$REMOTE" 2>"$TMP/rclone.err")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "openbao-remote-collect: rclone exit $rc: $(head -c 300 "$TMP/rclone.err" | tr -cd '\040-\176')" >&2
fi
{
    if [ "$rc" -ne 0 ] && [ -n "$(cl_previous "$STATUS" '^OBHEALTH marker=')" ]; then
        prev_seen=$(cl_previous "$STATUS" '^OBHEALTH generated=' | grep -oE 'seen=[0-9]+' | cut -d= -f2)
        echo "OBHEALTH generated=$START seen=${prev_seen:-0} rc=$rc lastfail=rclone-exit-$rc"
        cl_previous "$STATUS" '^OBHEALTH marker='
    else
        echo "OBHEALTH generated=$START seen=$START rc=$rc"
        printf '%s\n' "$markers" | tr -cd '\012\040-\176' \
            | grep -E '^OPENBAOHEALTH( [a-z_]+=[A-Za-z0-9-]+)+$' | sed 's/^/OBHEALTH marker=/'
    fi
    echo "OBHEALTH end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
