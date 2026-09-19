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
SOCK="/run/podman/podman.sock"
API="http://localhost/v5.0.0"

if [ -z "$KEY" ]; then
    echo "UNKNOWN - usage: check_google_oauth.sh <account-key>"
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

# The backend images are distroless -- no shell -- so the exec Cmd has to be
# python3 directly. The payload is base64'd and decoded inside Python to keep
# it clear of both JSON and shell quoting.
read -r -d '' PY <<'PYEOF'
import json, sys, urllib.request, urllib.parse, urllib.error
cred = sys.argv[1]
try:
    d = json.load(open(cred))
except Exception as e:
    print("OAUTH|NOCRED|%s" % type(e).__name__); raise SystemExit(0)
missing = [k for k in ("client_id", "client_secret", "refresh_token") if not d.get(k)]
if missing:
    print("OAUTH|NOTOKEN|%s" % ",".join(missing)); raise SystemExit(0)
body = urllib.parse.urlencode({
    "client_id": d["client_id"], "client_secret": d["client_secret"],
    "refresh_token": d["refresh_token"], "grant_type": "refresh_token"}).encode()
uri = d.get("token_uri") or "https://oauth2.googleapis.com/token"
try:
    r = urllib.request.urlopen(urllib.request.Request(uri, data=body), timeout=20)
    print("OAUTH|200|%s" % json.load(r).get("expires_in", "?"))
except urllib.error.HTTPError as e:
    try:
        err = json.loads(e.read()).get("error", "unknown")
    except Exception:
        err = "unknown"
    print("OAUTH|%d|%s" % (e.code, err))
except Exception as e:
    print("OAUTH|NET|%s" % type(e).__name__)
PYEOF

# base64 output is alphanumeric plus +/= only, so the payload needs no JSON
# escaping -- which matters because the agent image is minimal and ships no
# python of its own to escape it with.
B64=$(printf '%s' "$PY" | base64 -w0)
CODE="import base64;exec(base64.b64decode('$B64'))"

EXEC=$(curl -s --max-time 15 --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[\"python3\",\"-c\",\"$CODE\",\"$CRED\"]}" \
    "$API/containers/${CTR}/exec" 2>/dev/null)

ID=$(echo "$EXEC" | grep -o '"Id":"[^"]*' | cut -d'"' -f4)
if [ -z "$ID" ]; then
    echo "UNKNOWN - $LABEL: could not create exec in $CTR (is the container running?)"
    exit 3
fi

OUT=$(curl -s --max-time 40 --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d '{"Detach":false,"Tty":true}' "$API/exec/$ID/start" 2>/dev/null \
    | tr -d '\000-\011\013-\037')

# The podman exec stream interleaves binary frame headers with the payload, so
# strip control bytes above and then accept only the characters these fields can
# legitimately contain -- otherwise stray 0x01 bytes end up in the Nagios output.
LINE=$(echo "$OUT" | grep -oE 'OAUTH\|[A-Z0-9]+\|[A-Za-z0-9_,.?-]*' | head -1)
if [ -z "$LINE" ]; then
    echo "UNKNOWN - $LABEL: no verdict returned from $CTR"
    exit 3
fi

STATUS_FIELD=$(echo "$LINE" | cut -d'|' -f2)
DETAIL=$(echo "$LINE" | cut -d'|' -f3)

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
    *)
        echo "UNKNOWN - $LABEL: unexpected response from token endpoint (HTTP $STATUS_FIELD ${DETAIL})"
        exit 3
        ;;
esac
