#!/bin/bash
# skills-sync-collect.sh — read the seats' josui-skills sync markers off the NRPE hot path
#
# WHY. A josui-skills merge used to reach no seat until it restarted
# (crunchtools/developer#42). The seats now fast-forward their checkouts every
# 10 minutes and write one status line each; a timer on Dolza and on Exedore
# copies those lines to pcloud:Monitoring/SkillsSync/<host>.<seat>, because
# Nagios runs only here on gloval and cannot see a seat. This is the route
# Cold Copy Freshness already takes from Exedore.
#
# WHO RUNS THIS. check_skills_sync.sh starts it detached through
# `podman_exec.sh --detach` into nagios-agent.crunchtools.com whenever the
# status file is older than its REFRESH or missing, and judges the file the
# previous run wrote -- the collector pattern in backup-freshness-collect.sh,
# so the pCloud read never happens inside NRPE's command_timeout.
#
# WHAT IT WRITES. $STATE_DIR/skills-sync.status, replaced atomically:
#
#   SKSYNC generated=<epoch> seen=<epoch> rc=<rclone exit> [lastfail=<why>]
#   SKSYNC marker=SKILLSSYNC host=<h> seat=<s> written=<epoch> state=<state> head=<sha> origin=<sha> drift_since=<epoch> fetched=<epoch>
#   SKSYNC end=1
#
# One `rclone cat` reads every marker. A read that fails keeps the previous
# run's markers and their seen, so one slow pCloud listing is not a fleet of
# missing seats; the plugin turns a seen older than its STALE into UNKNOWN.
# Only marker lines that are plain key=value words survive into the file.
set -uo pipefail
# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3
RCLONE=${RCLONE:-/usr/local/bin/rclone}
CONF=${CONF:-/etc/nagios/rclone.conf}
REMOTE=${REMOTE:-pcloud:Monitoring/SkillsSync}
READ_T=${READ_T:-60}
STATUS="$STATE_DIR/skills-sync.status"

cl_lock skills-sync   # exits 0 when a run is already in progress
[ -x "$RCLONE" ] || { echo "$RCLONE not mounted into agent container" >&2; exit 3; }
[ -r "$CONF" ]   || { echo "$CONF not readable" >&2; exit 3; }

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

markers=$(timeout "$READ_T" "$RCLONE" --config "$CONF" cat "$REMOTE" 2>"$TMP/rclone.err")
rc=$?
# Why a read failed goes to this run's stderr (the detached exec's log), not
# into the status file the plugin prints: rclone's errors can name paths.
if [ "$rc" -ne 0 ]; then
    echo "skills-sync-collect: rclone exit $rc: $(head -c 300 "$TMP/rclone.err" | tr -cd '\040-\176')" >&2
fi
{
    if [ "$rc" -ne 0 ] && [ -n "$(cl_previous "$STATUS" '^SKSYNC marker=')" ]; then
        prev_seen=$(cl_previous "$STATUS" '^SKSYNC generated=' | grep -oE 'seen=[0-9]+' | cut -d= -f2)
        echo "SKSYNC generated=$START seen=${prev_seen:-0} rc=$rc lastfail=rclone-exit-$rc"
        cl_previous "$STATUS" '^SKSYNC marker='
    else
        echo "SKSYNC generated=$START seen=$START rc=$rc"
        printf '%s\n' "$markers" | tr -cd '\012\040-\176' \
            | grep -E '^SKILLSSYNC( [a-z_]+=[A-Za-z0-9-]+)+$' | sed 's/^/SKSYNC marker=/'
    fi
    echo "SKSYNC end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
