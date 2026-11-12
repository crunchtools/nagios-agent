#!/bin/bash
# =============================================================================
# check_mcp_tool.sh — does this MCP server still DO anything? (9.8.0, RT #1565)
# =============================================================================
# Usage: check_mcp_tool.sh <probe-key> [conf]
#
# The three checks every ctr-mcp-* host already has -- container running,
# container memory, TCP port -- all passed for the entire mcp-gemini outage of
# 2026-11-07, during which every single tool returned
#   "Gemini API error: Attempted to call a sync close on an async stream".
# Liveness was perfect and the server was useless. This check closes that gap:
# it speaks streamable-http to the server, calls one cheap read-only tool, and
# asserts a regex against the result.
#
# ASSERT THE SHAPE, NOT THE ABSENCE OF AN EXCEPTION. That outage returned a
# well-formed JSON-RPC 200 whose content was an error string, with isError
# false. A check that only confirmed "the server replied" would have stayed
# green throughout. The expect regex in mcp-probes.conf is the load-bearing
# part of this plugin; a probe row without a meaningful one is decoration.
#
# NO PYTHON, NO JQ. The nagios-agent image ships neither -- do not "clean this
# up" with either one. Beyond bash and curl this uses only what that image
# already has: grep, sed, awk, tr, cut, head, mktemp and timeout. Parsing is
# grep/sed over the one SSE data line, which is why PAYLOAD_MAX exists below.
#
# Runs on the :5667 container/slow pool (check_nrpe_ctr), with the other checks
# that block on somebody else's API. Not the :5666 host pool: a third-party
# outage must not be able to queue up behind the host diagnostics.
#
# TOKENS. Two servers want a bearer token (mcp-memory, mcp-grafana). Rather
# than keep a second copy in /srv or sops, field 4 of a probe row names the
# container and env var to read it out of, through the podman API socket this
# container already mounts. One source of truth, and it checks the token the
# server itself is actually running with. The value is never printed.
#
#   It is also never put in curl's ARGUMENT LIST. This container runs
#   --pid=host, so anything on the box that can read /proc/<pid>/cmdline could
#   lift the credential out of a running curl. The header goes in a 0600 temp
#   file passed as `-H @file`, which is the same reason notify_hermes.sh hands
#   curl its ingress token as `-H @<(...)` instead of inline.
#
# SESSIONS. Stateful servers (fastmcp default) hand back an mcp-session-id and
# want notifications/initialized before a call; the two stateless ones return
# no id and work without it. Both paths are handled, and a session is DELETEd
# on the way out -- 23 probes every 15 minutes otherwise leaks sessions into
# every server on the box forever.
# =============================================================================

set -uo pipefail

CONF="${2:-${MCP_PROBES_CONF:-/etc/nagios/mcp-probes.conf}}"
SOCK="${MCP_PODMAN_SOCK:-/run/podman/podman.sock}"
# Per-request ceiling. Three requests worst case, so the plugin stays inside
# the 45s that check_nrpe_ctr allows.
TIMEOUT="${MCP_PROBE_TIMEOUT:-12}"
# Only the head of the response is parsed. A tool that returns a megabyte of
# JSON would otherwise be grepped line-by-line in bash on every interval.
PAYLOAD_MAX="${MCP_PROBE_PAYLOAD_MAX:-65536}"
PROTO="2025-06-18"

# No WARNING state: a tool call either returns usable data or it does not.
OK=0; CRITICAL=2; UNKNOWN=3

die() { echo "UNKNOWN - $1"; exit $UNKNOWN; }
crit() { echo "CRITICAL - $1"; exit $CRITICAL; }

# Everything quoted from a server's reply goes through quote(). A Nagios plugin
# line travels to the Nagios log, the web UI and -- through notify_hermes.sh --
# to Hermes and Matrix, so a tool that echoes a credential in its error text
# must not put it there.
#
# This REDACTS rather than drops. The tool's own error text is the most useful
# thing in the page: "OAuth credentials expired or missing" is what let the
# mcp-gsc expiry be diagnosed and routed in under a minute, and a check that
# said only "the assertion failed" would send someone to read logs by hand.
#
# Scrub BEFORE truncating, or a cut can leave half a token on the line.
scrub() {
    # Specific, self-identifying shapes first, so a JWT or a provider token
    # keeps its informative label instead of being swallowed by the generic
    # keyword rule that follows. Any scheme in the URL rule, not just http:
    # a postgres:// or amqp:// connection string in an error carries a
    # password just as happily.
    sed -E \
        -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}[A-Za-z0-9._-]*/[REDACTED-JWT]/g' \
        -e 's/(gh[pousr]_|github_pat_|xox[baprs]-|glpat-|sk-ant-|sk-)[A-Za-z0-9_-]{8,}/[REDACTED-TOKEN]/g' \
        -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]@"]+:[^/[:space:]@"]+@#\1[REDACTED-USERINFO]@#g' \
        -e 's/(access_token|refresh_token|api_key|apikey|client_secret|id_token|sig|signature)=[^&[:space:]"]+/\1=[REDACTED]/Ig' \
        -e 's/(bearer|token|key|secret|password|passwd|authorization)([[:space:]]*[:=][[:space:]]*|[[:space:]]+)[A-Za-z0-9._~+/=-]{8,}/\1\2[REDACTED]/Ig'
}
quote() { tr '\n' ' ' | scrub | cut -c1-"${1:-160}"; }

KEY="${1:-}"
[[ -n "$KEY" ]] || die "usage: check_mcp_tool.sh <probe-key> [conf]"
[[ -r "$CONF" ]] || die "probe table $CONF is missing or unreadable"

# ---------------------------------------------------------------------------
# Probe row:  key|port|tool|token|scope|args_json|expect_regex
#
# scope is 'local' or 'upstream:<who>'. It is printed in the alert text, which
# is the whole payload notify_hermes.sh forwards to Kagetora, so the triaging
# agent can tell "our server is broken" from "GitHub is having a bad morning"
# without first going and reading this table. This check cannot distinguish the
# two at probe time -- an expired token, a server bug and a third-party outage
# all look identical from here -- so scope is a declared fact about the
# dependency, not a measurement.
#
# expect_regex is LAST and taken as the remainder of the line, so it may
# contain | for alternation. Nothing before it may.
# ---------------------------------------------------------------------------
ROW="$(grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$' \
       | awk -F'|' -v k="$KEY" '$1==k {print; exit}')"
[[ -n "$ROW" ]] || die "no probe row for '$KEY' in $CONF"

PORT="$(cut -d'|' -f2 <<<"$ROW")"
TOOL="$(cut -d'|' -f3 <<<"$ROW")"
TOKEN_SRC="$(cut -d'|' -f4 <<<"$ROW")"
SCOPE="$(cut -d'|' -f5 <<<"$ROW")"
ARGS="$(cut -d'|' -f6 <<<"$ROW")"
EXPECT="$(cut -d'|' -f7- <<<"$ROW")"

[[ "$PORT" =~ ^[0-9]+$ ]] || die "probe '$KEY' has a non-numeric port '$PORT'"
[[ -n "$TOOL" ]] || die "probe '$KEY' names no tool"
[[ -n "$EXPECT" ]] || die "probe '$KEY' has no expect regex -- it would pass on an error string"
[[ "$SCOPE" == "local" || "$SCOPE" == upstream:* ]] \
    || die "probe '$KEY' scope must be 'local' or 'upstream:<who>', got '$SCOPE'"
[[ -n "$ARGS" ]] || ARGS='{}'

# Prefix on every non-OK line. Kagetora keys its triage off this.
TAG="${KEY} [${SCOPE}]"

URL="http://127.0.0.1:${PORT}/mcp"
HDR_COMMON=(-H 'Content-Type: application/json'
            -H 'Accept: application/json, text/event-stream')

# ---------------------------------------------------------------------------
# Bearer token, read from the target container's own environment.
# ---------------------------------------------------------------------------
AUTH=()
SID=""
HDRFILE=""

# Set before the header file exists so no path can leak it. The session DELETE
# needs the auth header, so it runs before the file goes away.
cleanup() {
    if [[ -n "$SID" ]]; then
        curl -sS --max-time 5 -o /dev/null -X DELETE "$URL" \
            "${HDR_COMMON[@]}" "${AUTH[@]+"${AUTH[@]}"}" \
            -H "mcp-session-id: ${SID}" >/dev/null 2>&1
    fi
    [[ -n "$HDRFILE" ]] && rm -f "$HDRFILE"
    return 0
}
trap cleanup EXIT

if [[ -n "$TOKEN_SRC" && "$TOKEN_SRC" != "brokered" ]]; then
    TCTR="${TOKEN_SRC%%:*}"
    TVAR="${TOKEN_SRC##*:}"
    [[ -n "$TCTR" && -n "$TVAR" && "$TCTR" != "$TOKEN_SRC" ]] \
        || die "probe '$KEY' token field must be <container>:<ENV_VAR>, got '$TOKEN_SRC'"
    TOK="$(curl -s --max-time 10 --unix-socket "$SOCK" \
             "http://localhost/v5.0.0/containers/${TCTR}/json" 2>/dev/null \
           | tr ',' '\n' | sed -n "s/.*\"${TVAR}=\([^\"]*\)\".*/\1/p" | head -1)"
    # Not CRITICAL: an unreadable podman socket or a renamed env var is a fault
    # in this check, not in the server it is watching. Saying CRITICAL here
    # would blame the MCP server for the monitoring being broken.
    [[ -n "$TOK" ]] || die "could not read \$$TVAR from container $TCTR via $SOCK"
    # 0600 under umask 077, and `-H @file` so the token never reaches argv.
    HDRFILE="$(umask 077; mktemp 2>/dev/null)" \
        || die "could not create a private header file for the bearer token"
    printf 'Authorization: Bearer %s\n' "$TOK" > "$HDRFILE" \
        || die "could not write the bearer token header file"
    unset TOK
    AUTH=(-H "@${HDRFILE}")
fi

START=$SECONDS

# ---------------------------------------------------------------------------
# 1. initialize — also the transport probe. Headers and body both needed:
#    the session id is a header, the protocol error would be in the body.
# ---------------------------------------------------------------------------
INIT_RAW="$(curl -sS --max-time "$TIMEOUT" -D - -X POST "$URL" \
    "${HDR_COMMON[@]}" "${AUTH[@]+"${AUTH[@]}"}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${PROTO}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"nagios-check_mcp_tool\",\"version\":\"1.0\"}}}" \
    2>&1)"
RC=$?
if (( RC != 0 )); then
    crit "${TAG}: MCP initialize failed on 127.0.0.1:${PORT} (curl exit ${RC}): $(quote 120 <<<"$INIT_RAW")"
fi

HTTP_CODE="$(grep -a -o -m1 '^HTTP/[0-9.]* [0-9][0-9][0-9]' <<<"$INIT_RAW" | awk '{print $2}')"
if [[ "$TOKEN_SRC" == "brokered" ]]; then
    if [[ "$HTTP_CODE" == "401" ]] && grep -qai '^www-authenticate:[[:space:]]*bearer' <<<"$INIT_RAW"; then
        echo "OK - ${KEY} [${SCOPE}]: brokered backend up on port ${PORT} (401 challenge; the gateway holds the grant)"
        exit $OK
    fi
    crit "${TAG}: brokered backend expected a 401 Bearer challenge, got HTTP ${HTTP_CODE:-none} on port ${PORT}"
fi
if [[ -n "$HTTP_CODE" && ! "$HTTP_CODE" =~ ^2 ]]; then
    crit "${TAG}: MCP initialize returned HTTP ${HTTP_CODE} on port ${PORT}"
fi
if grep -qa '"error"[[:space:]]*:[[:space:]]*{' <<<"$INIT_RAW"; then
    crit "${TAG}: MCP initialize returned a JSON-RPC error: $(sed -n 's/.*"message":"\([^"]*\)".*/\1/p' <<<"$INIT_RAW" | head -1 | quote 140)"
fi

SID="$(tr -d '\r' <<<"$INIT_RAW" | awk 'tolower($1)=="mcp-session-id:"{print $2; exit}')"
SIDHDR=()
[[ -n "$SID" ]] && SIDHDR=(-H "mcp-session-id: ${SID}")

# Stateful servers reject tools/call before this; stateless ones 202/400 it
# harmlessly. Either way its result is not worth failing the check over.
if [[ -n "$SID" ]]; then
    curl -sS --max-time "$TIMEOUT" -o /dev/null -X POST "$URL" \
        "${HDR_COMMON[@]}" "${AUTH[@]+"${AUTH[@]}"}" "${SIDHDR[@]}" \
        -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# 2. tools/call — the actual point of this check.
# ---------------------------------------------------------------------------
BODY="$(curl -sS --max-time "$TIMEOUT" -X POST "$URL" \
    "${HDR_COMMON[@]}" "${AUTH[@]+"${AUTH[@]}"}" "${SIDHDR[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${TOOL}\",\"arguments\":${ARGS}}}" \
    2>&1 | head -c "$PAYLOAD_MAX")"
RC=$?
ELAPSED=$(( SECONDS - START ))

if (( RC != 0 )); then
    crit "${TAG}: ${TOOL} call failed (curl exit ${RC}) after ${ELAPSED}s: $(quote 120 <<<"$BODY")"
fi
[[ -n "$BODY" ]] || crit "${TAG}: ${TOOL} returned an empty response after ${ELAPSED}s"

# One line, SSE 'data:' payload if that is what came back, raw JSON otherwise.
PAYLOAD="$(grep -a '^data:' <<<"$BODY" | sed 's/^data:[[:space:]]*//' | tr -d '\n')"
[[ -n "$PAYLOAD" ]] || PAYLOAD="$(tr -d '\n' <<<"$BODY")"

# Transport-level JSON-RPC error (unknown tool, bad arguments, auth).
if grep -qa '"error"[[:space:]]*:[[:space:]]*{' <<<"$PAYLOAD"; then
    crit "${TAG}: ${TOOL} returned a JSON-RPC error: $(sed -n 's/.*"message":"\([^"]*\)".*/\1/p' <<<"$PAYLOAD" | head -1 | quote 140)"
fi
# Tool-level failure the server did flag.
if grep -qa '"isError"[[:space:]]*:[[:space:]]*true' <<<"$PAYLOAD"; then
    crit "${TAG}: ${TOOL} reported isError: $(sed -n 's/.*"text":"\([^"]*\)".*/\1/p' <<<"$PAYLOAD" | head -1 | quote)"
fi
if ! grep -qa '"result"' <<<"$PAYLOAD"; then
    crit "${TAG}: ${TOOL} answered without a result object: $(quote <<<"$PAYLOAD")"
fi

# The assertion that would have caught 2026-11-07: a 200 with isError false
# whose content was an error string.
if ! grep -Eqa -- "$EXPECT" <<<"$PAYLOAD"; then
    crit "${TAG}: ${TOOL} answered but the result does not match /${EXPECT}/ -- tool is reachable and broken: $(sed -n 's/.*"text":"\([^"]*\)".*/\1/p' <<<"$PAYLOAD" | head -1 | quote)"
fi

echo "OK - ${KEY} [${SCOPE}]: ${TOOL} returned a valid result in ${ELAPSED}s (matched /${EXPECT}/)"
exit $OK
