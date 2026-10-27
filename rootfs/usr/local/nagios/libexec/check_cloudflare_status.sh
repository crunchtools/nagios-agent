#!/bin/bash
# Check Cloudflare zone health: requests and cache ratio over the last 24h
# Usage: check_cloudflare_status.sh <domain-name>
#
# Judges the status file cloudflare-collect.sh writes; never calls Cloudflare
# itself (7.1.0). When the file is missing or older than REFRESH (2m, under the
# 3m check_interval) this starts the collector detached through
# `podman_exec.sh --detach` in nagios-agent-ctr.crunchtools.com and judges the
# previous run's file. See the collector's header for the format and for why
# the numbers now come from the GraphQL Analytics API.
#
# The zone ID is looked up by the collector from
# /etc/nagios/cloudflare-zones.conf, never passed as an argument. This repo is
# public, and an nrpe.cfg carrying zone IDs inline cannot be committed without
# publishing which zones belong to this account. The conf is a host file
# bind-mounted into the agent, one zone per line: <domain> <zone-id>
#
# Verdicts, unchanged from the live check: OK with requests and cached %, OK
# "no traffic" for zero requests. UNKNOWN when Cloudflare did not answer for
# the zone (API error with no earlier answer, or no answer for STALE, 10m),
# and "collector stale" when the status file is missing or older than STALE.

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    echo "UNKNOWN - usage: check_cloudflare_status.sh <domain-name>"
    exit 3
fi
if ! [[ $DOMAIN =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "UNKNOWN - invalid domain name"
    exit 3
fi

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/cloudflare.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/cloudflare-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-120}
STALE=${STALE:-600}

cl_open CF ""
line=$(grep -m1 -E "^CF zone=${DOMAIN//./\\.} " <<< "$CL_RAW")
if [ -z "$line" ]; then
    echo "UNKNOWN - $DOMAIN is not collected: no zone ID for it in cloudflare-zones.conf"
    exit 3
fi

seen=$(cl_field seen "$line")
since=$(( $(date +%s) - ${seen:-0} ))
age="collected_age=${CL_AGE}s;;${STALE}"
if [ "$since" -ge "$STALE" ]; then
    echo "UNKNOWN - $DOMAIN: not read from Cloudflare for $(cl_hm "$since")${CL_KICKED} | $age"
    exit 3
fi
if [ "$(cl_field result "$line")" != ok ]; then
    echo "UNKNOWN - $DOMAIN: Cloudflare analytics read failed: $(cl_field msg "$line")${CL_KICKED} | $age"
    exit 3
fi

TOTAL=$(cl_field requests "$line")
CACHED=$(cl_field cached "$line")

if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
    echo "OK - $DOMAIN: no traffic in last 24h${CL_KICKED} | requests=0;;;0; $age"
    exit 0
fi

PCT_CACHED=$((CACHED * 100 / TOTAL))

echo "OK - $DOMAIN: ${TOTAL} requests, ${PCT_CACHED}% cached${CL_KICKED} | requests=${TOTAL};;;0; cached_pct=${PCT_CACHED}%;;;0;100 $age"
exit 0
