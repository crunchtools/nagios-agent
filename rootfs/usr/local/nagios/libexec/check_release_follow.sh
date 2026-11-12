#!/bin/bash
# check_release_follow.sh — is the deployer's release follower running, and is
# anything it filed sitting where nobody reads it?
#
# release-follow (crunchtools/deployer 0.8.0) runs hourly and files an RT
# Deploy ticket when a followed service's :latest is newer than what it runs.
# A ticket the deployer hands back is stalled and owned by RT user `follower`,
# which no person reads. Its status file is the only place those tickets
# surface, so this check is what turns one into an alert.
#
# It reads one local file, written in the collector frame:
#
#   FOLLOWER generated=<epoch> outcome=ok|degraded|could-not-run detail=...
#   FOLLOWER service name=<svc> result=... ticket=<id|-> [followed= since=] detail=...
#   FOLLOWER stalled ticket=<id> service=<svc> commit=<sha12>
#   FOLLOWER end=1
#
# A plain check, not a collector (constitution XVI): the read is a local file.
# The follower's own `since=` lines are judged by check_deploy_drift.sh, not
# here; this check is about the follower itself.
#
# Verdicts:
#   OK        the last pass was whole, recent and ok, and no follower ticket
#             is stalled
#   WARNING   a stalled follower ticket (named, with service and commit); an
#             outcome other than ok; a file without end=1; or a pass older than
#             stale_hours, which means the hourly timer has stopped
#   UNKNOWN   the status file is missing or unreadable. The same treatment
#             check_deployer.sh gives a missing /var/lib/deployer: the check
#             cannot tell "not installed" from "broken", and it is only
#             configured once the follower is.
#
# WARNING, never CRITICAL: nothing is down. A release is waiting for a person.
#
# Usage: check_release_follow.sh [status-file] [stale_hours]

set -uo pipefail

STATUS=${1:-/var/lib/deployer/follower/release-follow.status}
STALE_HOURS=${2:-3}

OK=0; WARNING=1; UNKNOWN=3

if ! [[ "$STALE_HOURS" =~ ^[0-9]+$ ]] || [ "$STALE_HOURS" -eq 0 ]; then
    echo "RELEASE FOLLOW UNKNOWN - stale_hours must be a whole number above 0"
    exit $UNKNOWN
fi
STALE=$(( STALE_HOURS * 3600 ))

if [ ! -f "$STATUS" ] || [ ! -r "$STATUS" ]; then
    echo "RELEASE FOLLOW UNKNOWN - $STATUS is missing or unreadable: release-follow has never written it, or this agent cannot see it"
    exit $UNKNOWN
fi

raw=$(cat "$STATUS" 2>/dev/null) || {
    echo "RELEASE FOLLOW UNKNOWN - cannot read $STATUS"
    exit $UNKNOWN
}

# field <name> <line>: the value of name=..., or empty.
field() { [[ " $2 " =~ \ $1=([^ ]*)\  ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# end=1 is what proves the file was written whole; without it the contents are
# not evidence of anything, the same rule check_deployer.sh applies.
if ! grep -qx 'FOLLOWER end=1' <<< "$raw"; then
    echo "RELEASE FOLLOW WARNING - $STATUS has no end=1: the last pass did not finish writing it | stalled=0;;;0 age=0s;;$STALE"
    exit $WARNING
fi

head=$(grep -m1 '^FOLLOWER generated=' <<< "$raw")
generated=$(field generated "$head")
outcome=$(field outcome "$head")
detail=$(field detail "$head")
detail=${detail//_/ }   # the frame writes spaces as underscores
if ! [[ "$generated" =~ ^[0-9]+$ ]]; then
    echo "RELEASE FOLLOW WARNING - $STATUS has no generated= time | stalled=0;;;0 age=0s;;$STALE"
    exit $WARNING
fi

now=$(date +%s)
age=$(( now - generated ))
[ "$age" -lt 0 ] && age=0

stalled=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    stalled+=("$(field ticket "$line"):$(field service "$line")@$(field commit "$line")")
done < <(grep '^FOLLOWER stalled ' <<< "$raw")

perf="stalled=${#stalled[@]};;;0 age=${age}s;;$STALE"

# Every reason, in one line: a follower that stopped AND left tickets stalled
# is two things for a person to do, and naming one would hide the other.
reasons=()
if [ "$age" -ge "$STALE" ]; then
    reasons+=("last pass $(( age / 3600 ))h ago, release-follow.crunchtools.com.timer has stopped running it")
fi
if [ "${#stalled[@]}" -gt 0 ]; then
    list=$(IFS=,; echo "${stalled[*]}")
    reasons+=("${#stalled[@]} stalled follower ticket(s) nobody reads [$list]: read each one in RT, deploy or resolve it")
fi
# Named the other way round, as check_deployer.sh does: ok is fine, and
# everything else -- including an outcome added to the follower later -- warns.
if [ "$outcome" != "ok" ]; then
    reasons+=("last pass ended ${outcome:-without an outcome} (${detail:--})")
fi

if [ "${#reasons[@]}" -gt 0 ]; then
    msg=$(printf '%s; ' "${reasons[@]}")
    echo "RELEASE FOLLOW WARNING - ${msg%; } | $perf"
    exit $WARNING
fi

echo "RELEASE FOLLOW OK - last pass $(( age / 60 ))m ago: ${detail:--} | $perf"
exit $OK
