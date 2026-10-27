#!/bin/bash
# google-oauth-collect.sh — Google refresh-token tests off the NRPE hot path (7.1.0)
#
# THE PROBLEM. check_google_oauth.sh asked each MCP Google-Workspace backend to
# exchange its refresh token with Google on every run, inside NRPE's timeout.
# Google answers in well under a second most of the time and in tens of
# seconds some of the time, and those runs were UNKNOWN or check_nrpe's
# "CRITICAL - Socket timeout", which says nothing about the token.
#
# THE SPLIT. This script runs the same test for every account in
# google-accounts.conf, in parallel (15s to create the exec, 40s for it to
# answer), and writes google-oauth.status. The plugin judges that file and
# starts this script through `podman_exec.sh --detach` in
# nagios-agent-ctr.crunchtools.com when the file is older than its REFRESH (2m,
# under the 3m check_interval). Nagios is the clock; a flock stops overlapping
# runs.
#
# THE TEST is unchanged: the backend container exchanges its own refresh token
# over the podman socket, so this script never reads a credential, and the
# access token it gets back is discarded inside the backend. Only the account
# key, the answer's status and expires_in reach the status file; the label and
# credential path stay in the conf.
#
# WHAT IT WRITES, $STATE_DIR/google-oauth.status, replaced atomically:
#   GOAUTH generated=<epoch> elapsed=<s>
#   GOAUTH key=<key> seen=<epoch> result=<200|400|401|NOTOKEN|NOCRED> detail=<text>
#   GOAUTH key=<key> seen=<epoch> result=<NET|EXEC|NOVERDICT|other HTTP code> detail=<text>
#   GOAUTH end=1
#
# The first kind is an answer about the token. The second says the test could
# not be made (Google unreachable, a 5xx, the backend container not answering),
# so the previous answer is kept, seen and all, and the plugin turns one older
# than its STALE into UNKNOWN.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

ACCOUNTS=${GOOGLE_ACCOUNTS:-/etc/nagios/google-accounts.conf}
SOCK=${SOCK:-/run/podman/podman.sock}
API="http://localhost/v5.0.0"
STATUS="$STATE_DIR/google-oauth.status"

cl_lock google-oauth

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/res"

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

probe() { # <key> <container> <credential-path>: one GOAUTH line to $TMP/res/<key>
    local key=$1 ctr=$2 cred=$3 exec id out line
    local res="$TMP/res/$key"
    exec=$(curl -s --max-time 15 --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
        -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[\"python3\",\"-c\",\"$CODE\",\"$cred\"]}" \
        "$API/containers/${ctr}/exec" 2>/dev/null)
    id=$(echo "$exec" | grep -o '"Id":"[^"]*' | cut -d'"' -f4)
    if [ -z "$id" ]; then
        echo "GOAUTH key=$key seen=$(date +%s) result=EXEC detail=no_exec_in_container" > "$res"; return
    fi
    # The exec stream interleaves binary frame headers with the payload: strip
    # control bytes, then accept only the characters these fields can hold.
    out=$(curl -s --max-time 40 --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
        -d '{"Detach":false,"Tty":true}' "$API/exec/$id/start" 2>/dev/null \
        | tr -d '\000-\011\013-\037')
    line=$(echo "$out" | grep -oE 'OAUTH\|[A-Z0-9]+\|[A-Za-z0-9_,.?-]*' | head -1)
    if [ -z "$line" ]; then
        echo "GOAUTH key=$key seen=$(date +%s) result=NOVERDICT detail=none" > "$res"; return
    fi
    IFS='|' read -r _ result detail <<< "$line"
    echo "GOAUTH key=$key seen=$(date +%s) result=$result detail=${detail:-none}" > "$res"
}

if [ -r "$ACCOUNTS" ]; then
    while read -r key ctr cred _; do
        [[ $key =~ ^[A-Za-z0-9_-]+$ ]] || continue
        # Credential files are named for their account, so '@' is allowed.
        # A line that fails the check is reported, not skipped: a skip left
        # both accounts at "not collected yet" in 7.1.0.
        if [[ ! $ctr =~ ^[A-Za-z0-9._-]+$ || ! $cred =~ ^/[A-Za-z0-9._@/-]+$ ]]; then
            echo "GOAUTH key=$key seen=$(date +%s) result=BADCONF detail=container_or_path_rejected" > "$TMP/res/$key"
            continue
        fi
        probe "$key" "$ctr" "$cred" &
    done < <(awk '$1 !~ /^#/ && NF >= 3 { print $1, $2, $3 }' "$ACCOUNTS")
fi
wait

{
    echo "GOAUTH generated=$START elapsed=$(( $(date +%s) - START ))"
    for f in "$TMP"/res/*; do
        [ -e "$f" ] || continue
        line=$(cat "$f")
        case "$(cl_field result "$line")" in
            200|400|401|NOTOKEN|NOCRED) ;;
            *)  # Could not test this time: keep the last real answer if there is one.
                key=$(cl_field key "$line")
                prev=$(cl_previous "$STATUS" "^GOAUTH key=$key seen=[0-9]+ result=(200|400|401|NOTOKEN|NOCRED) " | head -1)
                [ -n "$prev" ] && line=$prev ;;
        esac
        echo "$line"
    done
    echo "GOAUTH end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
