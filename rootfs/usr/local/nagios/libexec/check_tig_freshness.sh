#!/bin/bash
# NRPE plugin: is Telegraf still delivering metrics to InfluxDB?
#
# Usage: check_tig_freshness.sh <warn-seconds> <crit-seconds>
#
# "Container running" and the port checks only show the three processes are
# alive. This is the check that shows the pipeline works: a collector can be up
# and writing nowhere, and the graphs just go flat. Asks InfluxDB for the age of
# its newest point over the Podman exec socket (constitution XVI: no token held
# by the monitoring agent).
#
# Service definition: crunchtools/tig deploy/nagios/tig.cfg.

WARN="${1:-300}"
CRIT="${2:-900}"
EXEC="$(dirname "$0")/podman_exec.sh"

age="$("$EXEC" influxdb.crunchtools.com /usr/local/bin/influxdb-freshness 2>/dev/null | tr -d '[:space:]')"

if ! [[ "$age" =~ ^-?[0-9]+$ ]]; then
    echo "UNKNOWN - could not read metric age from influxdb.crunchtools.com"
    exit 3
fi

if [ "$age" -lt 0 ]; then
    echo "CRITICAL - no Telegraf metrics in the last 24 hours | age=86400s;$WARN;$CRIT"
    exit 2
fi

if [ "$age" -ge "$CRIT" ]; then
    echo "CRITICAL - newest metric is ${age}s old | age=${age}s;$WARN;$CRIT"
    exit 2
fi

if [ "$age" -ge "$WARN" ]; then
    echo "WARNING - newest metric is ${age}s old | age=${age}s;$WARN;$CRIT"
    exit 1
fi

echo "OK - newest metric is ${age}s old | age=${age}s;$WARN;$CRIT"
exit 0
