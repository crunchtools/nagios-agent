#!/bin/bash
# Check Postiz OAuth integration tokens for expiry / refreshNeeded.
#
# Postiz has two classes of channel and they need opposite handling:
#
#   Self-renewing  - the provider stores a refresh token and Postiz runs a
#                    Temporal refreshTokenWorkflow that sleeps until the token's
#                    expiry and then renews it (threads, instagram-standalone).
#                    A near-expiry date on these is normal and not actionable,
#                    so days-based alerting is suppressed for them. They are
#                    still covered: if the renewal fails, Postiz sets
#                    refreshNeeded, and if the workflow is gone the token sails
#                    past expiry -- both go CRITICAL below.
#
#   Manual         - no refresh token, so Postiz can never renew it and a human
#                    has to redo the OAuth flow (linkedin). LinkedIn issues
#                    60-day tokens and once one lapses Postiz leaves posts
#                    sitting in QUEUE and raises no alarm of its own.
#
# Neither class alerts on a countdown. The Postiz UI only offers the reconnect
# once the channel is broken, so a warning weeks ahead is a nag with nothing to
# act on (Scott, 2026-10-24). Days left still show in the OK output; the check
# goes CRITICAL the moment a token expires or Postiz sets refreshNeeded.
#
# Usage: check_postiz_tokens.sh

LIST_DAYS=365
CTR="postiz.crunchtools.com"
SOCK="/run/podman/podman.sock"
API="http://localhost/v5.0.0"
UI="https://postiz.crunchtools.com"

# Rows are sentinel-prefixed because the podman exec stream prefixes an 8-byte
# binary frame header that otherwise glues itself onto the first row. The
# account name goes last so a stray delimiter in a display name can only garble
# that cosmetic field instead of shifting the numeric ones.
SQL='SELECT (chr(82)||chr(79)||chr(87)||chr(58)) || "providerIdentifier" || chr(124) || "refreshNeeded"::int || chr(124) || (CASE WHEN coalesce(length("refreshToken"),0) > 0 THEN 1 ELSE 0 END) || chr(124) || floor(EXTRACT(epoch FROM ("tokenExpiration" - now()))/86400)::int || chr(124) || name FROM "Integration" WHERE "deletedAt" IS NULL AND disabled = false ORDER BY "tokenExpiration";'
B64=$(printf '%s' "$SQL" | base64 -w0)

EXEC=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[\"sh\",\"-c\",\"echo $B64 | base64 -d | psql \\\"\$DATABASE_URL\\\" -t -A -f -\"]}" \
    "$API/containers/${CTR}/exec" 2>/dev/null)

ID=$(echo "$EXEC" | grep -o '"Id":"[^"]*' | cut -d'"' -f4)
if [ -z "$ID" ]; then
    echo "UNKNOWN - could not create exec in $CTR (is the container running?)"
    exit 3
fi

# Break the stream before every sentinel so a glued frame header cannot let the
# trailing free-text name field swallow the row behind it.
OUT=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d '{"Detach":false,"Tty":true}' "$API/exec/$ID/start" 2>/dev/null \
    | tr -d '\000\r' | sed 's/ROW:/\n&/g')

ROWS=$(echo "$OUT" | grep -oE 'ROW:[a-z0-9_-]+\|[01]\|[01]\|-?[0-9]+\|[^|]*' | sed 's/^ROW://')
if [ -z "$ROWS" ]; then
    echo "UNKNOWN - no integration rows returned from the Postiz database"
    exit 3
fi

CRIT=""; AUTO=""; MANUAL=""
while IFS='|' read -r PLATFORM REFRESH HASREF DAYS NAME; do
    [ -z "$PLATFORM" ] && continue
    LABEL="$PLATFORM (${NAME:-unknown})"

    if [ "$REFRESH" = "1" ]; then
        CRIT="$CRIT; $LABEL is disconnected and needs reconnecting now"
    elif [ "$DAYS" -le 0 ]; then
        CRIT="$CRIT; $LABEL expired ${DAYS#-}d ago"
    fi

    # Facebook, X, Mastodon and Bluesky carry expirations decades out. Listing
    # them adds nothing, so the OK summary only covers the next year.
    if [ "$DAYS" -le "$LIST_DAYS" ]; then
        if [ "$HASREF" = "1" ]; then
            AUTO="$AUTO $PLATFORM ${DAYS}d"
        else
            MANUAL="$MANUAL $PLATFORM ${DAYS}d"
        fi
    fi
done <<< "$ROWS"

COUNT=$(echo "$ROWS" | wc -l)
HOWTO="reconnect at $UI via Add Channel, signing in as the same account"

# Separator is " -- ", never "|": Nagios splits plugin output on the first pipe
# and files everything after it as performance data, which would strip the
# remedy text out of the alert and the notification mail.

if [ -n "$CRIT" ]; then
    echo "CRITICAL - Postiz:${CRIT#;} -- $HOWTO"
    exit 2
else
    echo "OK - $COUNT Postiz integrations valid${MANUAL:+ -- manual:$MANUAL}${AUTO:+ -- auto-renewing:$AUTO}"
    exit 0
fi
