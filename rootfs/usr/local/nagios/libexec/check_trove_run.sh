#!/bin/bash
# check_trove_run.sh — mcp-trove's last --index run finished recently and cleanly (RT #1542)
# Usage: check_trove_run.sh <last_run.json> [max-age-hours] [warn-error-pct]
#
# mcp-trove 0.10+ writes a summary after every nightly --index run. It is
# the one place that says whether the run actually did its job: the systemd
# unit can exit 0 on a run that indexed nothing, and a run killed by a reboot
# writes nothing at all. So:
#
#   CRITICAL  no summary, summary older than max-age-hours (default 36, so one
#             missed night is caught), or the run's status is not "ok": a path
#             aborted (source unmounted or hung), failed, was missing, or had
#             over 10% of its files fail; a backup or quick_check problem
#   WARNING   errored files above warn-error-pct (default 5) of those found;
#             the run spent its whole vision budget (files deferred to the next
#             night: fine during a backfill, a spend leak otherwise); no backup
#             recorded, or the newest one older than max-age-hours
#   UNKNOWN   sqlite3 absent, the summary unreadable or not valid JSON
#
# READ-ONLY, AS NRPE. The summary is 0644 and holds counts and statuses only.
# There is no jq or python in the agent image, so sqlite3 parses the JSON
# with readfile() and its JSON functions, in an in-memory database.

set -uo pipefail

FILE="${1:-}"
MAX_AGE_H="${2:-36}"
WARN_PCT="${3:-5}"
TMO=${SQLITE_TIMEOUT:-10}

if [ -z "$FILE" ]; then
    echo "TROVE RUN UNKNOWN - usage: check_trove_run.sh <last_run.json> [max-age-hours] [warn-error-pct]"
    exit 3
fi
# The path goes into a SQL string literal, so only plain path characters pass.
if ! [[ "$FILE" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "$FILE" == *..* ]]; then
    echo "TROVE RUN UNKNOWN - invalid summary path"
    exit 3
fi
if ! [[ "$MAX_AGE_H" =~ ^[0-9]+$ && "$WARN_PCT" =~ ^[0-9]+$ ]]; then
    echo "TROVE RUN UNKNOWN - max-age-hours and warn-error-pct must be non-negative integers"
    exit 3
fi

command -v sqlite3 >/dev/null || { echo "TROVE RUN UNKNOWN - sqlite3 not installed in the agent image"; exit 3; }
[ -e "$FILE" ] || { echo "TROVE RUN CRITICAL - no run summary at $FILE; no --index run has finished"; exit 2; }
[ -r "$FILE" ] || { echo "TROVE RUN UNKNOWN - $FILE is not readable by $(id -un)"; exit 3; }

# One query, one line, fields separated by \x1f so messages may hold any text.
read -r -d '' SQL <<EOF
WITH s AS (SELECT CAST(readfile('$FILE') AS TEXT) AS j),
p AS (SELECT value AS v FROM s, json_each(s.j, '\$.paths'))
SELECT json_valid(j),
       coalesce(json_extract(j, '\$.status'), ''),
       coalesce(round((julianday('now') - julianday(json_extract(j, '\$.finished_at'))) * 24, 1), -1),
       coalesce((SELECT group_concat(value, '; ') FROM json_each(s.j, '\$.problems')), ''),
       coalesce((SELECT group_concat(json_extract(v, '\$.path') || ' ' || json_extract(v, '\$.status'), ', ')
                 FROM p WHERE json_extract(v, '\$.status') != 'ok'), ''),
       coalesce((SELECT sum(json_extract(v, '\$.files_found')) FROM p), 0),
       coalesce((SELECT sum(json_extract(v, '\$.files_indexed')) FROM p), 0),
       coalesce((SELECT sum(json_extract(v, '\$.files_errored')) FROM p), 0),
       coalesce((SELECT sum(json_extract(v, '\$.files_deferred')) FROM p), 0),
       coalesce(json_extract(j, '\$.vision_calls'), 0),
       coalesce(json_extract(j, '\$.vision_budget'), 0),
       coalesce(round((julianday('now') - julianday(json_extract(j, '\$.latest_backup.created_at'))) * 24, 1), -1),
       coalesce(json_extract(j, '\$.duration_seconds'), 0)
FROM s;
EOF
out=$(timeout "$TMO" sqlite3 -batch -noheader -separator $'\x1f' :memory: "$SQL" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && out="parse timed out after ${TMO}s"
    echo "TROVE RUN UNKNOWN - $(printf '%s' "$out" | head -n1)"
    exit 3
fi

IFS=$'\x1f' read -r valid status age problems bad found indexed errored deferred calls budget backup_age duration <<< "$out"
if [ "$valid" != 1 ]; then
    echo "TROVE RUN UNKNOWN - $FILE is not valid JSON"
    exit 3
fi

perf="age_hours=${age};;${MAX_AGE_H};0 found=${found};;;0 indexed=${indexed};;;0 errored=${errored};;;0 deferred=${deferred};;;0 vision_calls=${calls};;${budget};0 duration=${duration}s;;;0"
# Shell arithmetic is integer-only; hours are compared after dropping the decimal.
age_whole=${age%.*}
backup_whole=${backup_age%.*}

if [ "$age_whole" -lt 0 ]; then
    echo "TROVE RUN UNKNOWN - $FILE has no finished_at | $perf"
    exit 3
fi
if [ "$age_whole" -ge "$MAX_AGE_H" ]; then
    echo "TROVE RUN CRITICAL - last index run finished ${age}h ago (max ${MAX_AGE_H}h); check mcp-trove-index.service and its timer | $perf"
    exit 2
fi
if [ "$status" != ok ]; then
    detail="${problems}${problems:+${bad:+; }}${bad}"
    echo "TROVE RUN CRITICAL - last index run ${status:-has no status}: ${detail:-see last_run.json} | $perf"
    exit 2
fi

warnings=()
if [ "$found" -gt 0 ] && [ $((errored * 100)) -gt $((found * WARN_PCT)) ]; then
    warnings+=("$errored of $found files failed")
fi
if [ "$budget" -gt 0 ] && [ "$calls" -ge "$budget" ]; then
    warnings+=("vision budget of $budget calls spent, $deferred files deferred")
fi
if [ "$backup_whole" -lt 0 ]; then
    warnings+=("no database backup recorded")
elif [ "$backup_whole" -ge "$MAX_AGE_H" ]; then
    warnings+=("newest database backup is ${backup_age}h old")
fi
if [ "${#warnings[@]}" -gt 0 ]; then
    msg=$(IFS=';'; printf '%s' "${warnings[*]}")
    echo "TROVE RUN WARNING - ${msg//;/; } | $perf"
    exit 1
fi

echo "TROVE RUN OK - finished ${age}h ago: $found files, $indexed indexed, $errored errored, $calls vision calls | $perf"
exit 0
