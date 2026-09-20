#!/bin/bash
# check_git_drift.sh — alert when /srv config has been out of sync with git (RT #1466)
#
# The failure this exists to catch: the trentina.crunchtools.com vhost was
# added live, never committed, and a container recreate discarded it. Config
# that is not committed is config you are one recreate away from losing.
#
# HOW IT MEASURES (changed under RT #1477). It used to read a status file
# published by a root systemd timer. The timer is gone; the agent image now
# ships git, so this plugin asks podman to run srv-drift-collect.sh as root in
# this container and parses the answer. Still a privilege split — nrpe never
# reads /var/srv itself, and nothing but counts and names crosses back — but
# the schedule now belongs to Nagios instead of a bespoke timer.
#
#   WARNING   drift older than 1h   — dashboard only, no notification
#   CRITICAL  drift older than 24h  — notifies
#   UNKNOWN   the collector could not be run, or answered garbage
#
# Thresholds are deliberately tight. Nagios here notifies on CRITICAL only
# (contacts.cfg, hermes, service_notification_options c), so a WARNING is a
# dashboard colour and costs nothing. There is no reason to tolerate an hour of
# unsaved config quietly.

set -uo pipefail

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/srv-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
WARN=${WARN:-3600}
CRIT=${CRIT:-86400}

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

raw=$("$EXEC" "$CONTAINER" "$COLLECT" 2>/dev/null)
rc=$?

[ "$rc" -eq 0 ] || { echo "GIT DRIFT UNKNOWN - collector exec in $CONTAINER exited $rc"; exit $UNKNOWN; }

# Anchored extraction, not a line parse: podman_exec.sh strips the libpod
# stream framing byte-wise and a stray printable byte can survive it.
field() { printf '%s\n' "$raw" | grep -m1 -oE "SRVDRIFT $1=.*" | cut -d= -f2- ; }

[ -n "$(field end)" ] || { echo "GIT DRIFT UNKNOWN - collector output truncated or unrecognised"; exit $UNKNOWN; }

error=$(field error)
[ -n "$error" ] && { echo "GIT DRIFT UNKNOWN - collector reported: $error"; exit $UNKNOWN; }

dirty_files=$(field dirty_files)
unpushed=$(field unpushed)
drift_since=$(field drift_since)
services=$(field services)

for v in "$dirty_files" "$unpushed" "$drift_since"; do
  case "$v" in ''|*[!0-9]*) echo "GIT DRIFT UNKNOWN - collector returned a non-numeric count"; exit $UNKNOWN ;; esac
done

now=$(date +%s)
perf="dirty=${dirty_files};;;0 unpushed=${unpushed};;;0"

if [ "$dirty_files" -eq 0 ] && [ "$unpushed" -eq 0 ]; then
  echo "GIT DRIFT OK - /srv clean and pushed | $perf drift_age=0s;${WARN};${CRIT};0"
  exit $OK
fi

drift_age=$(( now - drift_since ))
human=$(( drift_age / 3600 ))h
[ "$drift_age" -lt 3600 ] && human=$(( drift_age / 60 ))m

# Say which half is wrong; "uncommitted" and "committed but never pushed" are
# different mistakes with different fixes.
parts=""
[ "$dirty_files" -gt 0 ] && parts="${dirty_files} uncommitted"
[ "$unpushed" -gt 0 ] && parts="${parts:+$parts, }${unpushed} unpushed commit(s)"
[ -n "$services" ] && parts="$parts (${services})"

msg="/srv out of sync with git for ${human} - ${parts}"
full="$msg | $perf drift_age=${drift_age}s;${WARN};${CRIT};0"

if [ "$drift_age" -ge "$CRIT" ]; then echo "GIT DRIFT CRITICAL - $full"; exit $CRITICAL
elif [ "$drift_age" -ge "$WARN" ]; then echo "GIT DRIFT WARNING - $full"; exit $WARNING
else echo "GIT DRIFT OK - $full"; exit $OK; fi
