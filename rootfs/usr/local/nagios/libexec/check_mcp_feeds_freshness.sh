#!/bin/bash
# Check mcp-feeds (RSS/Atom feed reader) refresh freshness.
#
# RT #1470: nothing drives mcp-feeds refreshes on a schedule -- the only
# regular trigger is the weekly weekend-report's defensive refresh
# (Sat 09:00 ET). This check reads the fleet-wide newest `last_fetched`
# timestamp straight out of the feed reader's own sqlite db over the podman
# exec socket (same pattern as check_postiz_tokens.sh / check_google_oauth.sh)
# -- no MCP layer, no LLM, no credential. Thresholds are days, not hours,
# because the primary refresh path is weekly by design; see
# crunchtools/constitution "Monitoring Checks".
#
# Usage: check_mcp_feeds_freshness.sh [warn_days] [crit_days]

WARN_DAYS="${1:-8}"
CRIT_DAYS="${2:-10}"
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

AGE_DAYS=$(( (NOW_EPOCH - MOD_EPOCH) / 86400 ))

if [ "$AGE_DAYS" -ge "$CRIT_DAYS" ]; then
    echo "CRITICAL - mcp-feeds last refreshed ${AGE_DAYS}d ago (newest last_fetched: $LAST_FETCHED) [warn:${WARN_DAYS}d crit:${CRIT_DAYS}d] | age=${AGE_DAYS}d;${WARN_DAYS};${CRIT_DAYS};0"
    exit 2
elif [ "$AGE_DAYS" -ge "$WARN_DAYS" ]; then
    echo "WARNING - mcp-feeds last refreshed ${AGE_DAYS}d ago (newest last_fetched: $LAST_FETCHED) [warn:${WARN_DAYS}d crit:${CRIT_DAYS}d] | age=${AGE_DAYS}d;${WARN_DAYS};${CRIT_DAYS};0"
    exit 1
else
    echo "OK - mcp-feeds last refreshed ${AGE_DAYS}d ago (newest last_fetched: $LAST_FETCHED) | age=${AGE_DAYS}d;${WARN_DAYS};${CRIT_DAYS};0"
    exit 0
fi
