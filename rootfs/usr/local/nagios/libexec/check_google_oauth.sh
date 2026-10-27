#!/bin/bash
# Check that an MCP Google-Workspace backend still has a usable OAuth grant.
#
# When Google revokes or expires the refresh token, the backend silently loses
# Gmail/Drive access: every call starts failing with "ACTION REQUIRED: Google
# Authentication Needed" and nothing else in the stack notices. The personal
# account died this way on 2026-09-09 and went unseen for five days, until a
# weekend report was silently re-sent from the other account instead.
#
# METHOD: file mtime is not a usable signal -- gw-personal is only exercised
# weekly, so a stale credential file is normal there, and Google publishes no
# read-only "is this token alive" endpoint. The only honest test is to actually
# exchange the refresh token.
#
# The credential files are mode 0600 and the nrpe user must never be able to
# read OAuth secrets, so this does NOT read them. It asks the backend container
# to test its own credential via the podman socket -- the same approach
# check_postiz_tokens.sh uses. That container already has the credential
# mounted, a Python interpreter, and egress to Google. The access token it gets
# back is discarded and the credential file is never written.
#
# COLLECTOR (7.1.0). The exchange is an outside call, so it no longer runs
# inside NRPE's timeout: google-oauth-collect.sh runs it for every account and
# writes google-oauth.status, and this plugin judges that file. When the file
# is missing or older than REFRESH (2m, under the 3m check_interval) the
# collector is started detached through `podman_exec.sh --detach` in
# nagios-agent-ctr.crunchtools.com and the previous run's file is judged. A
# test that could not be made keeps the previous answer; one older than STALE
# (10m) is UNKNOWN, and so is a status file missing or older than STALE.
#
# Usage: check_google_oauth.sh <account-key>
#
# The account key is an opaque handle — "personal", "work". The container name,
# the credential path and the human label all resolve from
# /etc/nagios/google-accounts.conf, a host file bind-mounted into the agent:
#
#   <key> <container> <credential-path-in-container> <label>
#
# Taking them as arguments instead would put mail addresses into nrpe.cfg, and
# this repo is public. Comments and blank lines in the conf are ignored.

KEY="${1:-}"
ACCOUNTS="${GOOGLE_ACCOUNTS:-/etc/nagios/google-accounts.conf}"

if [ -z "$KEY" ]; then
    echo "UNKNOWN - usage: check_google_oauth.sh <account-key>"
    exit 3
fi
if ! [[ $KEY =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "UNKNOWN - invalid account key"
    exit 3
fi

if [ ! -r "$ACCOUNTS" ]; then
    echo "UNKNOWN - Cannot read $ACCOUNTS"
    exit 3
fi

read -r CTR CRED LABEL <<<"$(awk -v k="$KEY" '$1 !~ /^#/ && $1 == k { print $2, $3, $4; exit }' "$ACCOUNTS")"

if [ -z "$CTR" ] || [ -z "$CRED" ]; then
    echo "UNKNOWN - account key '$KEY' not found in $ACCOUNTS"
    exit 3
fi

LABEL="${LABEL:-$CTR}"

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/google-oauth.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/google-oauth-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-120}
STALE=${STALE:-600}

cl_open GOAUTH ""
LINE=$(grep -m1 -E "^GOAUTH key=$KEY " <<< "$CL_RAW")
if [ -z "$LINE" ]; then
    echo "UNKNOWN - $LABEL: not collected yet, the collector has no answer for '$KEY'${CL_KICKED}"
    exit 3
fi

SEEN=$(cl_field seen "$LINE")
SINCE=$(( $(date +%s) - ${SEEN:-0} ))
STATUS_FIELD=$(cl_field result "$LINE")
DETAIL=$(cl_field detail "$LINE")

# An answer about the token that is older than STALE is not judged, except a
# rejection: a token Google refused does not heal while nobody can look.
case "$STATUS_FIELD" in
    400|401|NOTOKEN|NOCRED) ;;
    *)
        if [ "$SINCE" -ge "$STALE" ]; then
            echo "UNKNOWN - $LABEL: token not tested for $(cl_hm "$SINCE") (last: ${STATUS_FIELD} ${DETAIL})${CL_KICKED}"
            exit 3
        fi ;;
esac

case "$STATUS_FIELD" in
    200)
        echo "OK - $LABEL: refresh token valid (access token good for ${DETAIL}s) | token_ok=1"
        exit 0
        ;;
    400|401)
        echo "CRITICAL - $LABEL: refresh token REJECTED (HTTP $STATUS_FIELD ${DETAIL}) - Google access is dead, browser re-consent needed | token_ok=0"
        exit 2
        ;;
    NOTOKEN)
        echo "CRITICAL - $LABEL: credential file holds no usable refresh token (missing: ${DETAIL}) - re-consent required | token_ok=0"
        exit 2
        ;;
    NOCRED)
        echo "CRITICAL - $LABEL: backend cannot read its credential file $CRED (${DETAIL}) | token_ok=0"
        exit 2
        ;;
    NET)
        echo "UNKNOWN - $LABEL: $CTR could not reach Google (${DETAIL}) - says nothing about the token"
        exit 3
        ;;
    EXEC)
        echo "UNKNOWN - $LABEL: could not create exec in $CTR (is the container running?)"
        exit 3
        ;;
    NOVERDICT)
        echo "UNKNOWN - $LABEL: no verdict returned from $CTR"
        exit 3
        ;;
    *)
        echo "UNKNOWN - $LABEL: unexpected response from token endpoint (HTTP $STATUS_FIELD ${DETAIL})"
        exit 3
        ;;
esac
