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
# A third filter, EXCLUDED_SCOPES (2026-11-08): the component filter alone is
# not enough, because Cloudflare files environment-scoped incidents under the
# ordinary component names. "Fedramp Customers have Delayed Purges" paged us
# as CDN Cache Purge for five hours while its own update read "Non-fedramp
# customers are not impacted." Nothing in the payload marks the scope -- the
# components[] entry is plain "CDN Cache Purge" and the group_id is the same
# one every component carries -- so the scope has to be read off the incident
# name. Only environments we categorically cannot be in are listed.
#
# Exit: 0 OK / 1 WARNING (relevant, minor) / 2 CRITICAL (relevant, major+) / 3 UNKNOWN

# Only the Cloudflare products crunchtools actually uses. Re-audited against
# the account 2026-11-08: four monitored Free-plan zones (crunchtools.com,
# educatedconfusion.com, fatherlinux.com, rootsofthevalley.org), proxied,
# Cloudflare-authoritative DNS, custom WAF rules with managed challenges,
# page rules, cache purge, and the API/dashboard behind mcp-cloudflare.
#
# Access and Zero Trust were added by that audit. Four self-hosted Access
# apps now gate nagios.crunchtools.com, learn.fatherlinux.com,
# rt.fatherlinux.com and dev.rootsofthevalley.org (created 2026-10-10 and
# 2026-11-05, after the previous audit). An Access outage locks Scott out of
# Nagios, the wiki and RT, and until now this check would have said OK
# through it. Incidents land on either name, so both are listed.
#
# Not used, so not listed: Recursive DNS (lotor resolves via Linode),
# Secondary DNS, Registrar, Always Online, Email Routing (mail is MX'd to
# self-hosted mail.crunchtools.com, not route*.mx.cloudflare.net), Workers,
# Pages, R2, Spectrum, Turnstile, Load Balancing. Zero Trust Dashboard is
# deliberately absent: losing it blocks policy edits, not Scott's logins.
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
Access
Zero Trust
API
Dashboard
"

# Incident names confined to a Cloudflare environment this account is
# categorically not in, matched case-insensitively against the incident name
# as an extended regex. Scope, not product: a product we do not use is
# already handled by RELEVANT_COMPONENTS, and anything listed here must be
# impossible for us by account type, never merely unlikely.
#   fedramp     - Cloudflare for Government, a physically separate FedRAMP
#                 edge. These zones are commercial Free plan.
#   china network - needs the Enterprise China Network add-on (JV with
#                 Baidu); Free-plan zones never route through it.
# Regional scope is NOT listed: "in Phoenix" still serves our visitors.
EXCLUDED_SCOPES=${EXCLUDED_SCOPES:-'fedramp|fed ramp|china network'}

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
    # Scope first: Cloudflare tags these with our component names, so the
    # component filter below cannot tell they do not reach this account.
    if printf '%s\n' "$NAME" | grep -qiE "$EXCLUDED_SCOPES"; then
        IRREL_COUNT=$((IRREL_COUNT + 1))
        [ -z "$IRREL_FIRST" ] && IRREL_FIRST="$NAME (out of scope)"
        continue
    fi
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
