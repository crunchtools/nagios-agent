#!/bin/bash
# Check mcp-feeds (RSS/Atom feed reader) refresh freshness.
#
# RT #1470. This check reads the fleet-wide newest `last_fetched` timestamp
# straight out of the feed reader's own sqlite db over the podman exec socket
# (same pattern as check_postiz_tokens.sh / check_google_oauth.sh) -- no MCP
# layer, no LLM, no credential.
#
# Thresholds are HOURS. They used to be days (8/10), set when the only regular
# trigger was the weekly weekend-report refresh. Since 2026-09-30 the crawl runs
# hourly plus once at 05:45 from mcp-feeds-refresh.timer on lotor (Scott's call:
# the timer stays), and the 06:00 daily briefing depends on it. A day-scale
# threshold is useless against that: the 2026-09-26 crawl outage ran four days
# and never tripped an 8-day WARN, while the briefing shipped with no news.
#
# The remediation still lives in Hermes, not here: the "mcp-feeds Refresh
# Watchdog" cron job reacts to this service going non-OK. See crunchtools/
# constitution "Monitoring Checks" -- that rule governs monitoring schedulers,
# which is why the remediation is a Hermes job and not a second timer.
#
# Usage: check_mcp_feeds_freshness.sh [warn_hours] [crit_hours]

WARN_HOURS="${1:-6}"
CRIT_HOURS="${2:-24}"
CTR="mcp-feeds"
SOCK="/run/podman/podman.sock"
API="http://localhost/v5.0.0"

PY_ARG="import sqlite3,os; c=sqlite3.connect('file:'+os.environ['FEED_READER_DB']+'?mode=ro',uri=True); r=c.execute('SELECT MAX(last_fetched) FROM feeds').fetchone()[0]; print('ROW:'+str(r))"
PY_ARG_ESCAPED=$(printf '%s' "$PY_ARG" | sed 's/\\/\\\\/g; s/"/\\"/g')

EXEC=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Tty\":true,\"Cmd\":[\"python\",\"-c\",\"${PY_ARG_ESCAPED}\"]}" \
    "$API/containers/${CTR}/exec" 2>/dev/null)

ID=$(echo "$EXEC" | grep -o '"Id":"[^"]*' | cut -d'"' -f4)
if [ -z "$ID" ]; then
    echo "UNKNOWN - could not create exec in $CTR (is the container running?)"
    exit 3
fi

OUT=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d '{"Detach":false,"Tty":true}' "$API/exec/$ID/start" 2>/dev/null | tr -d '\000\r')

LAST_FETCHED=$(echo "$OUT" | grep -oE 'ROW:[0-9TZ:.+-]+' | head -1 | sed 's/^ROW://')

if [ -z "$LAST_FETCHED" ]; then
    echo "UNKNOWN - could not read last_fetched from $CTR (output: $(echo "$OUT" | tr '\n' ' ' | cut -c1-150))"
    exit 3
fi

MOD_EPOCH=$(date -d "$LAST_FETCHED" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)

if [ -z "$MOD_EPOCH" ]; then
    echo "UNKNOWN - could not parse timestamp: $LAST_FETCHED"
    exit 3
fi

AGE_HOURS=$(( (NOW_EPOCH - MOD_EPOCH) / 3600 ))

if [ "$AGE_HOURS" -ge "$CRIT_HOURS" ]; then
    echo "CRITICAL - mcp-feeds last refreshed ${AGE_HOURS}h ago (newest last_fetched: $LAST_FETCHED) [warn:${WARN_HOURS}h crit:${CRIT_HOURS}h] | age=${AGE_HOURS}h;${WARN_HOURS};${CRIT_HOURS};0"
    exit 2
elif [ "$AGE_HOURS" -ge "$WARN_HOURS" ]; then
    echo "WARNING - mcp-feeds last refreshed ${AGE_HOURS}h ago (newest last_fetched: $LAST_FETCHED) [warn:${WARN_HOURS}h crit:${CRIT_HOURS}h] | age=${AGE_HOURS}h;${WARN_HOURS};${CRIT_HOURS};0"
    exit 1
else
    echo "OK - mcp-feeds last refreshed ${AGE_HOURS}h ago (newest last_fetched: $LAST_FETCHED) | age=${AGE_HOURS}h;${WARN_HOURS};${CRIT_HOURS};0"
    exit 0
fi
