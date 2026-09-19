#!/bin/bash
# Audit the running fleet against constitution XIII (Centralized Logging).
#
# A repo-level grep cannot answer "is this service actually reaching the
# collector" — that depends on the systemd unit and on runtime behaviour. This
# checks the fleet as it actually is, and reports two distinct failures:
#
#   1. A container whose log driver is not journald. Its output never reaches
#      conmon's journal tap, so it is invisible to the collector entirely.
#   2. A container that is running and using journald, but has no log directory
#      under the collector's log root. Usually a service that is genuinely silent,
#      but it is also what a broken ingest path looks like for one container.
#
# Usage: check_syslog_coverage.sh [log_root] [warn_count] [crit_count]

LOG_ROOT="${1:-/srv/syslog.crunchtools.com/data/logs}"
WARN_AT="${2:-1}"
CRIT_AT="${3:-5}"
SOCK=/run/podman/podman.sock

names=$(curl -s --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/libpod/containers/json" 2>/dev/null \
    | grep -o '"Names":\[[^]]*\]' | grep -o '"[^"]*"' | grep -v Names | tr -d '"')

if [ -z "$names" ]; then
    echo "UNKNOWN - could not enumerate containers via $SOCK"
    exit 3
fi

wrong_driver=""
no_logs=""
total=0

for name in $names; do
    total=$((total + 1))

    driver=$(curl -s --unix-socket "$SOCK" \
        "http://localhost/v5.0.0/containers/${name}/json" 2>/dev/null \
        | grep -o '"LogConfig":{[^}]*}' | grep -o '"Type":"[^"]*"' | cut -d'"' -f4)

    if [ -n "$driver" ] && [ "$driver" != "journald" ]; then
        wrong_driver="$wrong_driver $name($driver)"
        continue
    fi

    if [ ! -d "$LOG_ROOT/$name" ]; then
        no_logs="$no_logs $name"
    fi
done

bad=$(printf '%s' "$wrong_driver" | wc -w)
quiet=$(printf '%s' "$no_logs" | wc -w)
perf="containers=$total wrong_driver=$bad;$WARN_AT;$CRIT_AT;0 no_logs=$quiet"

# Only the log driver drives the alert state. "No collected logs" is reported but
# never pages: an idle MCP server that logs solely on request is indistinguishable
# from a broken one here, and alerting on it would page constantly for normal
# behaviour. Collector-wide ingest failure is caught by check_syslog_freshness.sh,
# which measures something unambiguous.
if [ "$bad" -ge "$CRIT_AT" ]; then
    echo "CRITICAL - $bad of $total containers bypass central logging:$wrong_driver | $perf"
    exit 2
elif [ "$bad" -ge "$WARN_AT" ]; then
    echo "WARNING - $bad of $total containers bypass central logging:$wrong_driver | $perf"
    exit 1
elif [ "$quiet" -gt 0 ]; then
    echo "OK - all $total containers use journald; $quiet quiet (no logs yet):$no_logs | $perf"
    exit 0
else
    echo "OK - all $total containers reaching the collector | $perf"
    exit 0
fi
