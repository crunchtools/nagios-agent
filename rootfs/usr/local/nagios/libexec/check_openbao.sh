#!/bin/bash
# check_openbao.sh -- is gloval's OpenBao up and unsealed? (RT#1604)
#
# WHY THIS IS A FLEET CHECK, NOT A SERVICE CHECK. Every srv-secrets@<svc>
# oneshot fetches from this server, and each service unit Requires= its
# oneshot. A sealed or dead OpenBao therefore does not degrade one service: it
# stops every service on the host from starting, and it does so silently until
# something restarts. Treat CRITICAL here as "the host cannot boot cleanly".
#
# It deliberately uses /v1/sys/health, which is UNAUTHENTICATED. No token,
# role_id or secret_id enters the monitoring path, so a compromised nagios-agent
# learns nothing about the secret store beyond whether it is sealed.
#
# Health codes, from the OpenBao API:
#   200 initialised, unsealed, active     -> OK
#   429 unsealed but standby              -> WARNING (single node: unexpected)
#   472 DR secondary / 473 perf standby   -> WARNING (not used here)
#   501 not initialised                   -> CRITICAL
#   503 sealed                            -> CRITICAL
#   000 no answer at all                  -> CRITICAL
#
# The CA is mounted into the nagios-agent container at /etc/nagios/openbao-ca.pem.
# It is a public certificate; nothing secret is mounted. Verification is NOT
# skipped -- an unverified loopback check would still pass if something else
# bound 8200.

ADDR=${OPENBAO_ADDR:-https://127.0.0.1:8200}
CA=${OPENBAO_CA:-/etc/nagios/openbao-ca.pem}
TIMEOUT=${OPENBAO_TIMEOUT:-8}

OK=0 WARNING=1 CRITICAL=2 UNKNOWN=3

if [ ! -r "$CA" ]; then
    echo "OPENBAO UNKNOWN - CA not readable at $CA (is it mounted into nagios-agent?)"
    exit $UNKNOWN
fi

body=$(curl -sS --cacert "$CA" --max-time "$TIMEOUT" \
        -w '\n%{http_code}' "$ADDR/v1/sys/health" 2>/dev/null)
code=$(printf '%s' "$body" | tail -1)
json=$(printf '%s' "$body" | sed '$d')

# Parsed with sed, not jq: the nagios-agent image ships curl and sed and has
# neither jq nor python3, so a jq-based plugin reports CRITICAL on a healthy
# server with every field empty. Found that way on 2026-11-09.
field_bool() { printf '%s' "$json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -1; }
field_str()  { printf '%s' "$json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

init=$(field_bool initialized)
sealed=$(field_bool sealed)
ver=$(field_str version)
perf="| sealed=${sealed:-U} http=${code:-000}"

case "$code" in
    200)
        if [ "$sealed" = "false" ] && [ "$init" = "true" ]; then
            echo "OPENBAO OK - unsealed and active, v${ver:-?} $perf"
            exit $OK
        fi
        echo "OPENBAO CRITICAL - HTTP 200 but initialized=$init sealed=$sealed $perf"
        exit $CRITICAL
        ;;
    429)
        echo "OPENBAO WARNING - unsealed but standby; single-node gloval should be active $perf"
        exit $WARNING
        ;;
    472|473)
        echo "OPENBAO WARNING - replication standby (HTTP $code), unexpected on gloval $perf"
        exit $WARNING
        ;;
    501)
        echo "OPENBAO CRITICAL - NOT INITIALISED. Every srv-secrets@ fetch will fail; the host cannot start its services. $perf"
        exit $CRITICAL
        ;;
    503)
        echo "OPENBAO CRITICAL - SEALED. The static seal should unseal unattended, so check that /etc/openbao/unseal.key is present and readable by uid 100, and see journalctl -u openbao.crunchtools.com. $perf"
        exit $CRITICAL
        ;;
    000|"")
        echo "OPENBAO CRITICAL - no answer from $ADDR. Check systemctl status openbao.crunchtools.com. $perf"
        exit $CRITICAL
        ;;
    *)
        echo "OPENBAO CRITICAL - unexpected HTTP $code from $ADDR $perf"
        exit $CRITICAL
        ;;
esac
