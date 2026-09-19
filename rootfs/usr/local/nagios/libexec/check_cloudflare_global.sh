#!/bin/bash
# Check Cloudflare for unresolved incidents (ignores scheduled maintenance).
#
# Two fixes over the original (2026-09-08):
#   1. The old parser took "impact" from the FIRST incident via `head -1` and
#      "name" from the LAST `"name":` anywhere in the payload via `tail -1`.
#      That last match is almost always a nested components[].name, so a real
#      CDN outage reported as: CRITICAL - Cloudflare: WARP.
#      Replaced with a depth-aware scanner that keys off position in the JSON
#      tree, so nested names can never be mistaken for the incident name.
#      (No jq/python in the NRPE container, hence gawk.)
#   2. Cloudflare posts minor incidents constantly for products we do not use
#      (WARP, Stream, Workers AI...). Only incidents touching a component in
#      RELEVANT_COMPONENTS can raise a non-OK state. Everything else is
#      reported in the OK line so it stays visible without paging.
#
# Exit: 0 OK / 1 WARNING (relevant, minor) / 2 CRITICAL (relevant, major+) / 3 UNKNOWN

# Components crunchtools actually depends on: proxied DNS + CDN for four zones,
# SSL provisioning, and the API/dashboard used by the cloudflare MCP server.
RELEVANT_COMPONENTS="
CDN/Cache
CDN Cache Purge
Authoritative DNS
DNS Updates
DNS Root Servers
Recursive DNS
Secondary DNS
Network
API
Dashboard
Firewall
Rules
Zones
SSL Certificate Provisioning
Registrar
Always Online
Challenge Platform
"

API_INCIDENTS='https://www.cloudflarestatus.com/api/v2/incidents/unresolved.json'
API_MAINT='https://www.cloudflarestatus.com/api/v2/scheduled-maintenances/active.json'

RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "$API_INCIDENTS" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo "UNKNOWN - Cannot reach Cloudflare status API"
    exit 3
fi

PARSER=$(cat <<'AWKEOF'
# Depth-aware JSON scanner for statuspage.io /incidents/unresolved.json
# Emits one line per incident:  idx|impact|status|name|comp1,comp2,...
# Keys are matched by their position in the document tree, never by order,
# so nested components[].name can never be mistaken for the incident name.
function unesc(s,   o, i, c) {
    o = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") {
            i++
            c = substr(s, i, 1)
            if      (c == "n") c = "\n"
            else if (c == "t") c = "\t"
            else if (c == "r") c = "\r"
            else if (c == "b") c = ""
            else if (c == "f") c = ""
            else if (c == "u") { i += 4; c = "?" }
        }
        o = o c
    }
    return o
}
{ doc = doc $0 "\n" }
END {
    n = length(doc)
    depth = 0
    i = 1
    while (i <= n) {
        c = substr(doc, i, 1)
        if (c == "\"") {
            # consume string
            str = ""
            i++
            while (i <= n) {
                c = substr(doc, i, 1)
                if (c == "\\") { str = str c substr(doc, i + 1, 1); i += 2; continue }
                if (c == "\"") { i++; break }
                str = str c
                i++
            }
            # look ahead: a ':' means this was a key
            j = i
            while (j <= n && substr(doc, j, 1) ~ /[ \t\r\n]/) j++
            if (substr(doc, j, 1) == ":") {
                ckey[depth] = unesc(str)
                i = j + 1
                continue
            }
            # otherwise it is a string value at ckey[depth]
            val = unesc(str)
            if (depth == 3 && ctype[3] == "o" && ctype[2] == "a" && ckey[1] == "incidents") {
                if (ckey[3] == "name")   name[idx[2]]   = val
                if (ckey[3] == "impact") impact[idx[2]] = val
                if (ckey[3] == "status") status[idx[2]] = val
            }
            if (depth == 5 && ctype[5] == "o" && ctype[4] == "a" && ckey[3] == "components" &&
                ctype[2] == "a" && ckey[1] == "incidents" && ckey[5] == "name") {
                comps[idx[2]] = (comps[idx[2]] == "" ? val : comps[idx[2]] "," val)
            }
            continue
        }
        if (c == "{") { depth++; ctype[depth] = "o"; ckey[depth] = ""; if (ctype[depth-1] == "a" && newelem[depth-1]) { idx[depth-1]++; newelem[depth-1] = 0 } ; i++; continue }
        if (c == "[") { depth++; ctype[depth] = "a"; idx[depth] = -1; newelem[depth] = 1; i++; continue }
        if (c == "}" || c == "]") { delete ckey[depth]; depth--; i++; continue }
        if (c == ",") { if (ctype[depth] == "a") newelem[depth] = 1; i++; continue }
        i++
    }
    for (k = 0; k <= maxidx(); k++) {
        if (k in name || k in impact) {
            printf "%d|%s|%s|%s|%s\n", k, impact[k], status[k], name[k], comps[k]
        }
    }
}
function maxidx(   k, m) { m = -1; for (k in name) if (k + 0 > m) m = k + 0; for (k in impact) if (k + 0 > m) m = k + 0; return m }
AWKEOF
)

INCIDENTS=$(printf '%s\n' "$RESPONSE" | gawk "$PARSER" 2>/dev/null)

if [ -z "$INCIDENTS" ]; then
    MAINT=$(curl -s --connect-timeout 5 "$API_MAINT" 2>/dev/null \
            | gawk "$PARSER" 2>/dev/null | head -1 | cut -d'|' -f4)
    if [ -n "$MAINT" ]; then
        echo "OK - No incidents. Maintenance: $MAINT"
    else
        echo "OK - All Cloudflare systems operational"
    fi
    exit 0
fi

# Partition incidents into relevant (touches a component we depend on) and not.
WORST=0            # 0 none, 1 minor, 2 major/critical
REL_MSG=""
REL_COUNT=0
IRREL_COUNT=0
IRREL_FIRST=""

while IFS='|' read -r IDX IMPACT STATUS NAME COMPS; do
    [ -z "$IMPACT$NAME" ] && continue
    MATCHED=""
    OLDIFS=$IFS
    IFS=','
    for C in $COMPS; do
        # exact, case-insensitive component-name match
        if printf '%s\n' "$RELEVANT_COMPONENTS" | grep -qixF "$C"; then
            MATCHED="${MATCHED:+$MATCHED, }$C"
        fi
    done
    IFS=$OLDIFS

    if [ -n "$MATCHED" ]; then
        REL_COUNT=$((REL_COUNT + 1))
        case "$IMPACT" in
            critical|major) SEV=2 ;;
            *)              SEV=1 ;;
        esac
        [ "$SEV" -gt "$WORST" ] && WORST=$SEV
        [ -z "$REL_MSG" ] && REL_MSG="$NAME [$IMPACT/$STATUS; $MATCHED]"
    else
        IRREL_COUNT=$((IRREL_COUNT + 1))
        [ -z "$IRREL_FIRST" ] && IRREL_FIRST="$NAME (${COMPS:-no components})"
    fi
done <<EOF
$INCIDENTS
EOF

SUFFIX=""
if [ "$IRREL_COUNT" -gt 0 ]; then
    # NB: no "|" here -- Nagios treats it as the perfdata separator and would
    # strip everything after it from the plugin output.
    SUFFIX=" [$IRREL_COUNT unrelated: $IRREL_FIRST]"
fi

if [ "$WORST" -eq 2 ]; then
    echo "CRITICAL - Cloudflare: $REL_MSG$SUFFIX"
    exit 2
elif [ "$WORST" -eq 1 ]; then
    echo "WARNING - Cloudflare: $REL_MSG$SUFFIX"
    exit 1
else
    echo "OK - No incidents affecting our components$SUFFIX"
    exit 0
fi
