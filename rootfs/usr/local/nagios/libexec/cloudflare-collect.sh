#!/bin/bash
# cloudflare-collect.sh — Cloudflare reads off the NRPE hot path (7.1.0)
#
# THE PROBLEM. check_cloudflare_status.sh (four zones) and
# check_cloudflare_global.sh asked Cloudflare live on every run, five calls
# every three minutes with no timeout on the zone call at all. A slow answer
# became "CRITICAL - Socket timeout" from check_nrpe, which says nothing about
# Cloudflare. Constitution XVI: slow or remote reads go through a collector.
#
# THE SPLIT. This script reads every zone in cloudflare-zones.conf and the
# public status page in one pass, in parallel, PROBE_T (20s) a call with one
# retry inside BUDGET (90s), and writes cloudflare.status. The two plugins only
# read that file. They start this script through `podman_exec.sh --detach` in
# nagios-agent-ctr.crunchtools.com when the file is older than their REFRESH
# (2m, under the 3m check_interval), so Nagios stays the clock. A flock stops
# overlapping runs; root is only the default exec user.
#
# ZONE ANALYTICS. The REST Zone Analytics API these checks used was sunset by
# Cloudflare (error 1015, "replaced by GraphQL API"). The old plugin read the
# error as zero requests and printed "OK - no traffic in last 24h" for every
# zone. This asks the GraphQL Analytics API for the last 24h of hourly
# request groups, and an error is an error.
#
# THE TOKEN goes to curl in a 0600 config file, never on its command line:
# with --pid=host an argv is readable from every process on the box. Nothing
# from the token or the zone IDs reaches the status file, which names zones by
# domain only.
#
# WHAT IT WRITES, $STATE_DIR/cloudflare.status, replaced atomically:
#   CF generated=<epoch> elapsed=<s>
#   CF zone=<domain> seen=<epoch> result=ok requests=<n> cached=<n>
#   CF zone=<domain> seen=<epoch> result=error msg=<text>
#   CF global seen=<epoch> result=ok
#   CF global seen=<epoch> result=error msg=<text>
#   CF incident=<idx>|<impact>|<status>|<name>|<comp1,comp2,...>
#   CF maint=<name of an active scheduled maintenance>
#   CF end=1
#
# seen is when Cloudflare last answered for that item. A call that fails keeps
# the previous run's answer, seen and all (the global answer keeps its incident
# and maint lines with it); the plugins turn an answer older than their STALE
# into UNKNOWN. Facts only: every threshold and the relevant-component filter
# live in the plugins.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

ZONES=${CF_ZONES:-/etc/nagios/cloudflare-zones.conf}
TOKEN_FILE=${CF_TOKEN:-/etc/nagios/cloudflare.token}
GRAPHQL=${CF_GRAPHQL:-https://api.cloudflare.com/client/v4/graphql}
STATUS_API=${CF_STATUS_API:-https://www.cloudflarestatus.com/api/v2}
BUDGET=${BUDGET:-90}    # seconds for the whole run
PROBE_T=${PROBE_T:-20}  # seconds a call
STATUS="$STATE_DIR/cloudflare.status"

cl_lock cloudflare

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/res"

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
            if      (c == "n") c = " "
            else if (c == "t") c = " "
            else if (c == "r") c = ""
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

# fetch <out-file> <curl args...>: one call with one retry, inside the budget.
# Returns curl's exit code; the body lands in <out-file>.
fetch() {
    local out=$1 rc=1 tries=0 left t
    shift
    while [ "$tries" -lt 2 ]; do
        left=$(( START + BUDGET - $(date +%s) ))
        [ "$left" -lt 2 ] && return 28
        t=$(( left < PROBE_T ? left : PROBE_T ))
        curl -sS --connect-timeout 10 --max-time "$t" "$@" > "$out" 2>"$out.err" && return 0
        rc=$?
        tries=$((tries + 1))
    done
    return "$rc"
}

# curl_err <file> <rc>: a one-word reason for a failed call
curl_err() { cl_clean "curl_exit_$2:$(head -1 "$1.err" 2>/dev/null)"; }

probe_zone() { # <domain> <zone-id>: one CF zone line to $TMP/res/zone.<domain>
    local domain=$1 id=$2 body="$TMP/zone.$1" since until rc msg req cached head
    local res="$TMP/res/zone.$domain"
    since=$(date -u -d "@$((START - 86400))" +%Y-%m-%dT%H:%M:%SZ)
    until=$(date -u -d "@$START" +%Y-%m-%dT%H:%M:%SZ)
    fetch "$body" -K "$TMP/auth" -H 'Content-Type: application/json' \
            --data-binary "{\"query\":\"{ viewer { zones(filter: {zoneTag: \\\"$id\\\"}) { httpRequests1hGroups(limit: 48, filter: {datetime_geq: \\\"$since\\\", datetime_lt: \\\"$until\\\"}) { sum { requests cachedRequests } } } } }\"}" \
            "$GRAPHQL"
    rc=$?
    head="CF zone=$domain seen=$(date +%s)"
    if [ "$rc" -ne 0 ]; then
        echo "$head result=error msg=$(curl_err "$body" "$rc")" > "$res"; return
    fi
    if ! grep -q '"errors": *null' "$body" && grep -q '"errors": *\[ *{' "$body"; then
        msg=$(grep -oP '"message": *"\K[^"]+' "$body" | head -1)
        echo "$head result=error msg=$(cl_clean "api:${msg:-unknown_error}")" > "$res"; return
    fi
    if ! grep -q '"httpRequests1hGroups"' "$body"; then
        msg=no_data; grep -q '"zones": *\[ *\]' "$body" && msg=zone_not_visible_to_token
        echo "$head result=error msg=$msg" > "$res"; return
    fi
    # Without dimensions the groups come back summed into one, but add them up
    # in case Cloudflare splits them. "cachedRequests" does not match "requests".
    req=$(grep -oP '"requests": *\K[0-9]+' "$body" | awk '{s += $1} END {print s + 0}')
    cached=$(grep -oP '"cachedRequests": *\K[0-9]+' "$body" | awk '{s += $1} END {print s + 0}')
    echo "$head result=ok requests=$req cached=$cached" > "$res"
}

probe_global() { # the status page: CF global, incident and maint lines to $TMP/res/global
    local res="$TMP/res/global" rc
    fetch "$TMP/incidents" "$STATUS_API/incidents/unresolved.json"; rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '"incidents"' "$TMP/incidents"; then
        [ "$rc" -eq 0 ] && rc=unparseable
        echo "CF global seen=$(date +%s) result=error msg=$(curl_err "$TMP/incidents" "$rc")" > "$res"; return
    fi
    {
        echo "CF global seen=$(date +%s) result=ok"
        gawk "$PARSER" "$TMP/incidents" 2>/dev/null | sed 's/^/CF incident=/'
    } > "$res.tmp"
    # Maintenance is only shown when nothing is broken, so it is only read then.
    if ! grep -q '^CF incident=' "$res.tmp" \
        && fetch "$TMP/maint" "$STATUS_API/scheduled-maintenances/active.json"; then
        gawk "$PARSER" "$TMP/maint" 2>/dev/null | head -1 | cut -d'|' -f4 \
            | grep . | sed 's/^/CF maint=/' >> "$res.tmp"
    fi
    mv "$res.tmp" "$res"
}

# The auth header as a curl config file in the 0700 temp dir, so the token is
# never in an argv and a retry can read it again (stdin could only be read once).
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
[ -n "$TOKEN" ] && (umask 077; printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$TMP/auth")
unset TOKEN
probe_global &
if [ -r "$ZONES" ]; then
    while read -r domain id _; do
        [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || continue
        if ! [[ $id =~ ^[0-9a-f]{32}$ ]]; then
            echo "CF zone=$domain seen=$START result=error msg=bad_zone_id_in_conf" > "$TMP/res/zone.$domain"
        elif [ ! -s "$TMP/auth" ]; then
            echo "CF zone=$domain seen=$START result=error msg=cannot_read_token" > "$TMP/res/zone.$domain"
        else
            probe_zone "$domain" "$id" &
        fi
    done < <(awk '$1 !~ /^#/ && NF >= 2 { print $1, $2 }' "$ZONES")
fi
wait

{
    echo "CF generated=$START elapsed=$(( $(date +%s) - START ))"
    for f in "$TMP"/res/zone.*; do
        [ -e "$f" ] || continue
        line=$(cat "$f")
        case "$line" in
            *" result=error "*)
                # Could not look this time: keep the last real answer if there is one.
                domain=$(cl_field zone "$line")
                prev=$(cl_previous "$STATUS" "^CF zone=${domain//./\\.} seen=[0-9]+ result=ok " | head -1)
                [ -n "$prev" ] && line=$prev ;;
        esac
        echo "$line"
    done
    line=$(head -1 "$TMP/res/global" 2>/dev/null)
    if [[ $line == *" result=ok"* ]] || ! cl_previous "$STATUS" '^CF global seen=[0-9]+ result=ok' >/dev/null; then
        cat "$TMP/res/global" 2>/dev/null \
            || echo "CF global seen=$START result=error msg=probe_wrote_nothing"
    else
        cl_previous "$STATUS" '^CF (global|incident=|maint=)'
    fi
    echo "CF end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
