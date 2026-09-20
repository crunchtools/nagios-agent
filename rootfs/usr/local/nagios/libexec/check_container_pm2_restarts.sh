#!/bin/bash
# Check pm2 restart counts inside a container via the Podman API exec endpoint.
# Usage: check_container_pm2_restarts.sh <container> [warn] [crit]
# Default: warn=1, crit=3.
#
# 2026-09-08: rewritten. The previous version matched "restart_time" within
# [^}]* of "name", but pm2 nests restart_time inside pm2_env, so the match never
# succeeded and every app silently reported 0. It sat green through a frontend
# crash-loop that took Postiz down. Parse the JSON with node inside the target
# container instead of with regex out here, and use a sentinel prefix because
# the exec stream glues an 8-byte binary frame header onto the first row.

CONTAINER="$1"
WARN="${2:-1}"
CRIT="${3:-3}"
SOCK="/run/podman/podman.sock"
API="http://localhost/v5.0.0"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn] [crit]"
    exit 3
fi

read -r -d '' NODE_SRC <<'JS'
let s='';
process.stdin.on('data', d => s += d).on('end', () => {
  try {
    const j = JSON.parse(s.slice(s.indexOf('[')));
    j.forEach(p => {
      const e = p.pm2_env || {};
      const r = (e.restart_time == null) ? 0 : e.restart_time;
      const u = (e.unstable_restarts == null) ? 0 : e.unstable_restarts;
      console.log('ROW:' + p.name + '|' + r + '|' + u + '|' + (e.status || 'unknown'));
    });
  } catch (err) { console.log('PARSEFAIL:' + err.message); }
});
JS
B64=$(printf '%s' "$NODE_SRC" | base64 -w0)

EXEC_RESP=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Tty\":true,\"Cmd\":[\"sh\",\"-c\",\"pm2 jlist 2>/dev/null | node -e \\\"\$(echo $B64 | base64 -d)\\\"\"]}" \
    "$API/containers/${CONTAINER}/exec" 2>/dev/null)

EXEC_ID=$(echo "$EXEC_RESP" | grep -o '"Id":"[^"]*' | cut -d'"' -f4)
if [ -z "$EXEC_ID" ]; then
    echo "UNKNOWN - Could not create exec in $CONTAINER (is it running?)"
    exit 3
fi

RAW=$(curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
    -d '{"Detach":false,"Tty":true}' "$API/exec/${EXEC_ID}/start" 2>/dev/null | tr -d '\000\r')

if echo "$RAW" | grep -q 'PARSEFAIL:'; then
    echo "UNKNOWN - could not parse pm2 output from $CONTAINER: $(echo "$RAW" | grep -o 'PARSEFAIL:.*' | head -1)"
    exit 3
fi

ROWS=$(echo "$RAW" | grep -oE 'ROW:[A-Za-z0-9_.-]+\|[0-9]+\|[0-9]+\|[a-z]+' | sed 's/^ROW://')
if [ -z "$ROWS" ]; then
    echo "UNKNOWN - no pm2 apps returned from $CONTAINER"
    exit 3
fi

MAX_RESTARTS=0; MAX_NAME=""; DETAILS=""; STOPPED=""
while IFS='|' read -r NAME RESTARTS UNSTABLE STATUS; do
    [ -z "$NAME" ] && continue
    [ -n "$DETAILS" ] && DETAILS="$DETAILS, "
    DETAILS="${DETAILS}${NAME}=${RESTARTS}"
    [ "$STATUS" != "online" ] && STOPPED="$STOPPED $NAME($STATUS)"
    if [ "$RESTARTS" -gt "$MAX_RESTARTS" ] 2>/dev/null; then
        MAX_RESTARTS=$RESTARTS; MAX_NAME=$NAME
    fi
done <<< "$ROWS"

if [ -n "$STOPPED" ]; then
    echo "CRITICAL - pm2 app not online:${STOPPED} | $DETAILS"
    exit 2
elif [ "$MAX_RESTARTS" -ge "$CRIT" ] 2>/dev/null; then
    echo "CRITICAL - $MAX_NAME crash-looping ($MAX_RESTARTS restarts) | $DETAILS"
    exit 2
elif [ "$MAX_RESTARTS" -ge "$WARN" ] 2>/dev/null; then
    echo "WARNING - $MAX_NAME restarted ($MAX_RESTARTS restarts) | $DETAILS"
    exit 1
else
    echo "OK - No restarts | $DETAILS"
    exit 0
fi
