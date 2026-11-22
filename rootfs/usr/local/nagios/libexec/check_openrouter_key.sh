#!/bin/bash
# Check how much of an OpenRouter key's spending limit is left (a953).
#
# Trentina's L3 judge runs on each profile's own OpenRouter key, and a key
# that reaches its limit gets HTTP 403 (scope key_limit) on every call until
# the limit resets. On 2026-11-22 JOSUI_OPENROUTER_API_KEY did exactly that and
# took L3 away from three profiles; nothing said so until reads failed. This
# reads the key's own limit_remaining before it gets there.
#
# The key never leaves the container that holds it. The plugin asks that
# container, through the podman socket, to read its own secret file and call
# GET https://openrouter.ai/api/v1/key. Only the secret's NAME is on the
# command line, and only numbers come back.
#
#   OK        no limit set, or more than WARN% of the limit left
#   WARNING   WARN% or less left
#   CRITICAL  CRIT% or less left, the key refused (401/403), or nothing left
#   UNKNOWN   the exec, the secret file or the API call failed
#
# Usage: check_openrouter_key.sh <container> <secret-name> [warn%] [crit%]
#   check_openrouter_key.sh trentina JOSUI_OPENROUTER_API_KEY 20 5
#
# OPENROUTER_SECRETS_DIR overrides where the container keeps its secret files.

EXEC=${PODMAN_EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
SECRETS_DIR=${OPENROUTER_SECRETS_DIR:-/run/trentina-secrets}
CONTAINER="${1:-}"
NAME="${2:-}"
WARN="${3:-20}"
CRIT="${4:-5}"

unknown() { echo "OPENROUTER KEY UNKNOWN - $1"; exit 3; }

[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || unknown "invalid container name"
[[ "$NAME" =~ ^[A-Z][A-Z0-9_]*$ ]] || unknown "invalid secret name"
[[ "$WARN" =~ ^[0-9]+$ && "$CRIT" =~ ^[0-9]+$ ]] || unknown "thresholds must be whole percents"
[ "$CRIT" -le "$WARN" ] || unknown "critical threshold above warning"

# Runs inside the container. It prints one line, and never the key or an
# exception's message: only a class name and an HTTP status.
read -r -d '' PY <<'PYEOF'
import json, sys, urllib.request, urllib.error
path = sys.argv[1] + "/" + sys.argv[2]
try:
    with open(path) as f:
        key = f.read().strip()
except OSError as e:
    print("NOFILE", type(e).__name__); sys.exit(0)
req = urllib.request.Request("https://openrouter.ai/api/v1/key", headers={"Authorization": "Bearer " + key})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.load(r).get("data") or {}
except urllib.error.HTTPError as e:
    print("HTTP", e.code); sys.exit(0)
except Exception as e:
    print("FAIL", type(e).__name__); sys.exit(0)
def num(v):
    return "none" if v is None else "%.4f" % float(v)
print("KEY", num(d.get("limit")), num(d.get("limit_remaining")), d.get("limit_reset") or "never")
PYEOF

OUT=$("$EXEC" "$CONTAINER" python3 -c "$PY" "$SECRETS_DIR" "$NAME" 2>&1)
RC=$?
LINE=$(grep -E '^(KEY|HTTP|NOFILE|FAIL) ' <<<"$OUT" | tail -1)
[ "$RC" -eq 0 ] && [ -n "$LINE" ] || unknown "$NAME: could not run the probe in $CONTAINER (rc=$RC)"

read -r KIND A B C <<<"$LINE"
case "$KIND" in
    NOFILE) unknown "$NAME: no readable secret file in $CONTAINER" ;;
    FAIL)   unknown "$NAME: OpenRouter key API unreachable ($A)" ;;
    HTTP)
        case "$A" in
            401|403) echo "OPENROUTER KEY CRITICAL - $NAME: OpenRouter refused the key (HTTP $A)"; exit 2 ;;
            *)       unknown "$NAME: OpenRouter key API answered HTTP $A" ;;
        esac ;;
esac

LIMIT="$A"; LEFT="$B"; RESET="$C"
[[ "$LIMIT" == none || "$LIMIT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || unknown "$NAME: unreadable limit"
if [ "$LIMIT" = none ]; then
    echo "OPENROUTER KEY OK - $NAME: no spending limit set"
    exit 0
fi
[[ "$LEFT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || unknown "$NAME: limit set but no limit_remaining"

# Percent left, the verdict, and perfdata in dollars with the thresholds the
# percents stand for.
read -r PCT STATE W C <<<"$(awk -v l="$LIMIT" -v r="$LEFT" -v w="$WARN" -v c="$CRIT" 'BEGIN {
    p = (l > 0) ? 100 * r / l : 0
    s = (r <= 0 || p <= c) ? 2 : (p <= w) ? 1 : 0
    printf "%.0f %d %.2f %.2f\n", p, s, l * w / 100, l * c / 100 }')"
MSG=$(awk -v l="$LIMIT" -v r="$LEFT" 'BEGIN { printf "$%.2f of $%.2f left", r, l }')
LABELS=(OK WARNING CRITICAL)
PERF=$(awk -v l="$LIMIT" -v r="$LEFT" -v w="$W" -v c="$C" 'BEGIN { printf "remaining=%.2f;%s;%s;0;%.2f", r, w, c, l }')
echo "OPENROUTER KEY ${LABELS[$STATE]} - $NAME: $MSG (${PCT}%), resets $RESET | $PERF"
exit "$STATE"
