#!/bin/bash
# check_deployer.sh — holds the deploy robot has placed, and whether anything
# still honours them.
#
# Reads the host, not the deployer's own status file. That file is written only
# when a ticket runs, so its age says nothing about whether a hold is current: a
# hold placed last week sits under a `generated=` from last week too. Holds are
# files, and files are what this reads.
#
# This is a plain check and not a collector (constitution XVI): everything it
# reads is local — a directory listing and one systemctl property — so there is
# nothing slow to move off the check path.
#
# Verdicts:
#   OK        no holds, and the auto-update hold guard is installed
#   WARNING   a hold exists, or the deployer's last run failed
#   CRITICAL  a hold exists but nothing honours it (the guard is gone);
#             a hold has stood for 24h or more; or a rollback failed to verify
#   UNKNOWN   the state directory cannot be read
#
# The guard case is CRITICAL rather than WARNING on purpose. A hold with no
# guard reads as protection that is not there, and the image that was rolled
# back goes live again at the next auto-update.
#
# Usage: check_deployer.sh [state-dir]

set -uo pipefail

STATE_DIR=${1:-/var/lib/deployer}
# Overridable the way collector-lib.sh overrides EXEC, so the branches that
# depend on the guard can be exercised on a host that has no auto-update unit.
SYSTEMCTL=${SYSTEMCTL:-systemctl}
HOLD_DIR="$STATE_DIR/hold"
STATUS_FILE="$STATE_DIR/deployer.status"
GUARD_UNIT="podman-auto-update.service"
STALE_HOLD_SECONDS=$(( 24 * 60 * 60 ))

if [ ! -d "$STATE_DIR" ] || [ ! -r "$STATE_DIR" ]; then
    echo "UNKNOWN - deployer state directory $STATE_DIR is missing or unreadable"
    exit 3
fi

# ---- holds ----

# An absent hold directory means no holds have ever been placed, which is the
# normal state. One that EXISTS but cannot be listed or traversed is a
# different thing entirely: holds may be sitting in it unseen, and reporting OK
# would be reporting a guess. That is UNKNOWN.
if [ -e "$HOLD_DIR" ] && { [ ! -r "$HOLD_DIR" ] || [ ! -x "$HOLD_DIR" ] || [ ! -d "$HOLD_DIR" ]; }; then
    echo "UNKNOWN - deployer hold directory $HOLD_DIR exists but cannot be listed: holds may be present and unseen"
    exit 3
fi

holds=()
oldest_age=0
if [ -d "$HOLD_DIR" ]; then
    now=$(date +%s)
    for path in "$HOLD_DIR"/*; do
        [ -f "$path" ] || continue
        unit=${path##*/}
        case $unit in .*) continue ;; esac   # the scratch file of an in-flight write
        placed=$(stat -c %Y "$path" 2>/dev/null || echo "$now")
        age=$(( now - placed ))
        [ "$age" -gt "$oldest_age" ] && oldest_age=$age
        ticket=$(grep -o '"ticket"[[:space:]]*:[[:space:]]*[0-9]*' "$path" 2>/dev/null \
                 | grep -o '[0-9]*$' | head -1)
        holds+=("${unit}:$(( age / 3600 ))h:${ticket:-?}")
    done
fi

# ---- the guard that honours them ----

guard=$($SYSTEMCTL show -p ExecCondition --value "$GUARD_UNIT" 2>/dev/null)

# ---- the last run ----

last_outcome=""
if [ -r "$STATUS_FILE" ]; then
    # end=1 is what proves the file was written whole; without it the contents
    # are not evidence of anything.
    if grep -qx 'DEPLOYER end=1' "$STATUS_FILE" 2>/dev/null; then
        line=$(grep -m1 '^DEPLOYER generated=' "$STATUS_FILE" 2>/dev/null)
        [[ $line =~ (^| )outcome=([^ ]*) ]] && last_outcome=${BASH_REMATCH[2]}
    else
        last_outcome="truncated"
    fi
fi

held_list=$(IFS=,; echo "${holds[*]-}")
perf="held=${#holds[@]};;;0 oldest_hold=${oldest_age}s;;${STALE_HOLD_SECONDS}"

# ---- verdict ----

if [ "${#holds[@]}" -gt 0 ] && [ -z "$guard" ]; then
    echo "CRITICAL - ${#holds[@]} hold(s) [$held_list] but no ExecCondition on $GUARD_UNIT: nothing honours them, so the rolled-back image goes live at the next auto-update | $perf"
    exit 2
fi

if [ "$oldest_age" -ge "$STALE_HOLD_SECONDS" ]; then
    echo "CRITICAL - a deployer hold has stood for $(( oldest_age / 3600 ))h [$held_list]: fleet updates are frozen for it until someone clears it | $perf"
    exit 2
fi

if [ "$last_outcome" = "rollback-failed" ]; then
    echo "CRITICAL - the deployer's last run rolled back and the rollback did not verify [$held_list] | $perf"
    exit 2
fi

if [ "${#holds[@]}" -gt 0 ]; then
    echo "WARNING - ${#holds[@]} deployer hold(s): $held_list | $perf"
    exit 1
fi

if [ -n "$last_outcome" ] && [ "$last_outcome" != "ok" ]; then
    echo "WARNING - the deployer's last run ended $last_outcome | $perf"
    exit 1
fi

if [ -z "$guard" ]; then
    echo "WARNING - no ExecCondition on $GUARD_UNIT: nothing holds yet, but a rollback would not stick | $perf"
    exit 1
fi

echo "OK - no deployer holds, hold guard installed | $perf"
exit 0
