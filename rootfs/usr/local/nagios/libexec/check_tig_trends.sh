#!/bin/bash
# NRPE plugin: is any Grafana trend rule firing?
#
# Usage: check_tig_trends.sh
#
# The tig slope rules (disk fills within 7 days, memory runs out within 24h,
# swap growth, container reaches its limit) do not page anyone. This check is
# how they surface: WARNING while one fires, with what it fired for. It never
# returns CRITICAL, because a trend is something to look at, not an outage.
# Runs grafana-firing inside the Grafana container over the Podman exec socket
# (constitution XVI: no credential held by the monitoring agent).
#
# Service definition: crunchtools/tig deploy/nagios/tig.cfg.

EXEC=${PODMAN_EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
MAX_OUTPUT=300

out="$("$EXEC" grafana.crunchtools.com /usr/local/bin/grafana-firing 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
    echo "UNKNOWN - could not read Grafana alert rules: $(head -1 <<<"$out")"
    exit 3
fi

firing="$(grep -c . <<<"$out")"
if [ "$firing" -eq 0 ]; then
    echo "OK - no trend alert firing | firing=0"
    exit 0
fi

summary="$(paste -sd ';' <<<"$out" | sed 's/;/; /g')"
[ "${#summary}" -gt "$MAX_OUTPUT" ] && summary="${summary:0:$MAX_OUTPUT}..."
echo "WARNING - $summary | firing=$firing"
exit 1
