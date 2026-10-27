#!/bin/bash
# Check Cloudflare for unresolved incidents (ignores scheduled maintenance).
#
# Judges cloudflare.status from cloudflare-collect.sh; never calls
# cloudflarestatus.com itself (7.1.0, constitution XVI).
#
# Two fixes over the original (2026-09-08):
#   1. The old parser took "impact" from the FIRST incident via `head -1` and
#      "name" from the LAST `"name":` anywhere in the payload via `tail -1`.
#      That last match is almost always a nested components[].name, so a real
#      CDN outage reported as: CRITICAL - Cloudflare: WARP.
#      Replaced with a depth-aware scanner that keys off position in the JSON
#      tree, so nested names can never be mistaken for the incident name.
#      (No jq/python in the NRPE container, hence gawk.) The scanner now
#      lives in cloudflare-collect.sh.
#   2. Cloudflare posts minor incidents constantly for products we do not use
#      (WARP, Stream, Workers AI...). Only incidents touching a component in
#      RELEVANT_COMPONENTS can raise a non-OK state. Everything else is
#      reported in the OK line so it stays visible without paging.
#
# Exit: 0 OK / 1 WARNING (relevant, minor) / 2 CRITICAL (relevant, major+) / 3 UNKNOWN

# Only the Cloudflare products crunchtools actually uses (checked against the
# account 2026-09-29): four Free-plan zones, proxied, Cloudflare-authoritative
# DNS, custom WAF rules with managed challenges, page rules, cache purge, and
# the API/dashboard behind mcp-cloudflare. Not used, so not listed: Recursive
# DNS (lotor resolves via Linode), Secondary DNS, Registrar, Always Online.
# "Network" is deliberately absent: it is tagged on every regional latency
# blip (an APAC degradation paged us on 2026-09-29), and an outage that
# actually reaches our zones also names CDN/Cache or Authoritative DNS.
# Names must match cloudflarestatus.com components exactly (case-insensitive).
RELEVANT_COMPONENTS="
Authoritative DNS
DNS Updates
CDN/Cache
CDN Cache Purge
SSL Certificate Provisioning
Firewall
Rules
Challenge Platform
API
Dashboard
"

# The status page is read by cloudflare-collect.sh, which also runs the
# depth-aware parser; this plugin judges what it wrote (7.1.0). When the file
# is missing or older than REFRESH (2m, under the 3m check_interval) the
# collector is started detached and the previous run's file is judged.
# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/cloudflare.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/cloudflare-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-120}
STALE=${STALE:-600}

cl_open CF ""
GLOBAL=$(grep -m1 '^CF global ' <<< "$CL_RAW")
SEEN=$(cl_field seen "$GLOBAL")
SINCE=$(( $(date +%s) - ${SEEN:-0} ))

if [ -z "$GLOBAL" ] || [ "$(cl_field result "$GLOBAL")" != ok ]; then
    WHY=$(cl_field msg "$GLOBAL")
    echo "UNKNOWN - Cannot reach Cloudflare status API (${WHY:-no answer recorded})${CL_KICKED}"
    exit 3
fi
if [ "$SINCE" -ge "$STALE" ]; then
    echo "UNKNOWN - Cloudflare status API not read for $(cl_hm "$SINCE")${CL_KICKED}"
    exit 3
fi

INCIDENTS=$(sed -n 's/^CF incident=//p' <<< "$CL_RAW")

if [ -z "$INCIDENTS" ]; then
    MAINT=$(sed -n 's/^CF maint=//p' <<< "$CL_RAW" | head -1)
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

while IFS='|' read -r _ IMPACT ISTATUS NAME COMPS; do
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
        [ -z "$REL_MSG" ] && REL_MSG="$NAME [$IMPACT/$ISTATUS; $MATCHED]"
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
