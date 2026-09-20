#!/bin/bash
# Check Postiz OAuth integration tokens for expiry / refreshNeeded.
# LinkedIn issues 60-day tokens and stores no refresh token, so it has to be
# reconnected by hand in the Postiz UI roughly every two months. When it
# lapses, Postiz leaves posts sitting in QUEUE and raises no alarm of its own.
# Usage: check_postiz_tokens.sh [warn_days] [crit_days]

WARN_DAYS="${1:-21}"
CRIT_DAYS="${2:-7}"
CTR="postiz.crunchtools.com"
SOCK="/run/podman/podman.sock"
API="http://localhost/v5.0.0"

# Rows are sentinel-prefixed because the podman exec stream prefixes an 8-byte
# binary frame header that otherwise glues itself onto the first row.
SQL='SELECT (chr(82)||chr(79)||chr(87)||chr(58)) || "providerIdentifier" || chr(124) || "refreshNeeded"::int || chr(124) || floor(EXTRACT(epoch FROM ("tokenExpiration" - now()))/86400)::int FROM "Integration" WHERE "deletedAt" IS NULL AND disabled = false ORDER BY "tokenExpiration";'
B64=$(printf '%s' "$SQL" | base64 -w0)

EXEC=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[\"sh\",\"-c\",\"echo $B64 | base64 -d | psql \\\"\$DATABASE_URL\\\" -t -A -f -\"]}" \
    "$API/containers/${CTR}/exec" 2>/dev/null)

ID=$(echo "$EXEC" | grep -o '"Id":"[^"]*' | cut -d'"' -f4)
if [ -z "$ID" ]; then
    echo "UNKNOWN - could not create exec in $CTR (is the container running?)"
    exit 3
fi

OUT=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d '{"Detach":false,"Tty":true}' "$API/exec/$ID/start" 2>/dev/null | tr -d '\000\r')

ROWS=$(echo "$OUT" | grep -oE 'ROW:[a-z0-9_-]+\|[01]\|-?[0-9]+' | sed 's/^ROW://')
if [ -z "$ROWS" ]; then
    echo "UNKNOWN - no integration rows returned from the Postiz database"
    exit 3
fi

CRIT=""; WARN=""; SOONEST=""; SOONEST_DAYS=""
while IFS='|' read -r PLATFORM REFRESH DAYS; do
    [ -z "$PLATFORM" ] && continue
    if [ "$REFRESH" = "1" ]; then
        CRIT="$CRIT $PLATFORM(needs reconnect)"
    elif [ "$DAYS" -le 0 ]; then
        CRIT="$CRIT $PLATFORM(expired ${DAYS#-}d ago)"
    elif [ "$DAYS" -le "$CRIT_DAYS" ]; then
        CRIT="$CRIT $PLATFORM(${DAYS}d)"
    elif [ "$DAYS" -le "$WARN_DAYS" ]; then
        WARN="$WARN $PLATFORM(${DAYS}d)"
    fi
    if [ -z "$SOONEST_DAYS" ] || [ "$DAYS" -lt "$SOONEST_DAYS" ]; then
        SOONEST_DAYS="$DAYS"; SOONEST="$PLATFORM"
    fi
done <<< "$ROWS"

COUNT=$(echo "$ROWS" | wc -l)

if [ -n "$CRIT" ]; then
    echo "CRITICAL - Postiz tokens need attention:${CRIT}${WARN:+ | warning:$WARN} (reconnect in the Postiz UI)"
    exit 2
elif [ -n "$WARN" ]; then
    echo "WARNING - Postiz tokens expiring soon:${WARN} (reconnect in the Postiz UI)"
    exit 1
else
    echo "OK - $COUNT Postiz integrations valid, soonest is $SOONEST in ${SOONEST_DAYS}d"
    exit 0
fi
