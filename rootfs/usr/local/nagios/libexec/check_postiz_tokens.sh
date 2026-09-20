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
#                    has to redo the OAuth flow (linkedin). These are what the
#                    day thresholds exist for. LinkedIn issues 60-day tokens and
#                    once one lapses Postiz leaves posts sitting in QUEUE and
#                    raises no alarm of its own.
#
# Reconnecting is "Add Channel -> <provider>, same account" rather than clicking
# the channel: the in-place reconnect badge only renders once refreshNeeded is
# set, so it is unavailable for a planned re-auth. Re-running the OAuth flow
# upserts on (organizationId, internalId), updating the existing channel rather
# than creating a duplicate, so queued posts survive.
#
# Usage: check_postiz_tokens.sh [warn_days] [crit_days]

WARN_DAYS="${1:-21}"
CRIT_DAYS="${2:-7}"
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

CRIT=""; WARN=""; AUTO=""; MANUAL=""
while IFS='|' read -r PLATFORM REFRESH HASREF DAYS NAME; do
    [ -z "$PLATFORM" ] && continue
    LABEL="$PLATFORM (${NAME:-unknown})"

    if [ "$REFRESH" = "1" ]; then
        CRIT="$CRIT; $LABEL is disconnected and needs reconnecting now"
    elif [ "$DAYS" -le 0 ]; then
        CRIT="$CRIT; $LABEL expired ${DAYS#-}d ago"
    elif [ "$HASREF" = "1" ]; then
        : # self-renewing and not yet broken -- reported, never alerted on
    elif [ "$DAYS" -le "$CRIT_DAYS" ]; then
        CRIT="$CRIT; $LABEL expires in ${DAYS}d and cannot auto-renew"
    elif [ "$DAYS" -le "$WARN_DAYS" ]; then
        WARN="$WARN; $LABEL expires in ${DAYS}d and cannot auto-renew"
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

if [ -n "$CRIT" ]; then
    echo "CRITICAL - Postiz:${CRIT#;}${WARN:+ | also warning:${WARN#;}} | $HOWTO"
    exit 2
elif [ -n "$WARN" ]; then
    echo "WARNING - Postiz:${WARN#;} | $HOWTO"
    exit 1
else
    echo "OK - $COUNT Postiz integrations valid, none expiring within ${WARN_DAYS}d |${MANUAL:+ manual:$MANUAL}${AUTO:+ | auto-renewing:$AUTO}"
    exit 0
fi
