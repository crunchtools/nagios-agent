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

# curl's own diagnostic is KEPT, not discarded. Without it a timeout, a TLS
# verification failure and a refused connection all arrive as the same "no
# answer", which is the difference between "openbao is down", "the CA is wrong"
# and "nothing is listening" -- three different things to go and do at 3am.
# It goes to a file rather than into $body, because $body is parsed positionally
# (last line is the HTTP code) and mixing stderr in would corrupt that.
# The fallback is an EMPTY err, never /dev/null. With err=/dev/null the EXIT
# trap below runs `rm -f /dev/null`, and this check runs as root under NRPE --
# that unlinks the system's null device and breaks every process that opens it.
# Caught by Gatehouse at HIGH on PR #158 before it ever ran as root.
err=$(mktemp "${TMPDIR:-/tmp}/.openbao-check.XXXXXX" 2>/dev/null) || err=
trap 'if [ -n "$err" ]; then rm -f "$err"; fi' EXIT
body=$(curl -sS --cacert "$CA" --max-time "$TIMEOUT" \
        -w '\n%{http_code}' "$ADDR/v1/sys/health" 2>"${err:-/dev/null}")
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
# PERFDATA MUST BE NUMERIC. Nagios perfdata values are numbers or U -- "true"
# and "false" are neither, so `sealed=true` was never graphable and this check
# had been presenting an ungraphable metric as a graphable one since it shipped
# (found by Gatehouse on PR #158, confidence 95, 3/3 votes). 1 is sealed, 0 is
# unsealed, U is "could not tell". The human-readable half of the output keeps
# the words, because that is what gets read in an alert.
case "$sealed" in
    true)  sealed_num=1 ;;
    false) sealed_num=0 ;;
    *)     sealed_num=U ;;
esac
perf="| sealed=$sealed_num http=${code:-000}"

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
        # Name the transport failure rather than making someone re-run curl by
        # hand: a timeout, a TLS verification error and a refused connection are
        # three different things to go and do something about.
        #
        # It goes BEFORE $perf. Everything after the pipe is perfdata, so any
        # prose appended after it is parsed as a metric and the whole perfdata
        # string is discarded -- which would have cost the graph to add a
        # diagnostic to the output.
        why=$(tr -d '\r' < "${err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-120)
        echo "OPENBAO CRITICAL - no answer from $ADDR${why:+ - $why}. Check systemctl status openbao.crunchtools.com. $perf"
        exit $CRITICAL
        ;;
    *)
        echo "OPENBAO CRITICAL - unexpected HTTP $code from $ADDR $perf"
        exit $CRITICAL
        ;;
esac
