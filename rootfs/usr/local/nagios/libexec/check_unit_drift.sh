#!/bin/bash
# check_unit_drift.sh — alert when running units differ from their /srv copy (RT #1466)
#
# The companion to check_git_drift.sh. That one guards /srv -> git. This one
# guards /etc -> /srv, which is the door nobody was watching:
#
#   you edit /etc/systemd/system/foo.service to fix something live
#   /srv/foo/config/foo.service is untouched, so it still matches git
#   every drift check reads green
#   git is now holding a definition that would break the service if restored
#
# Found exactly that on nagios-agent.crunchtools.com.service -- the committed
# copy was missing the rclone mounts check_backup_freshness depends on, so
# restoring it from git would have broken backup verification. 11 units had
# drifted that way and 38 more ran from /etc with no /srv copy at all.
#
# Two conditions, different fixes, so they are reported separately:
#   mismatch   /srv and /etc differ    -> decide which is right, usually /etc
#   unbacked   no /srv copy exists     -> copy it in and commit
#
# GRACE (7.0.0). This used to warn the moment the two copies differed, with no
# threshold, on the theory that there is no benign window. There is one: every
# unit deploy is "edit /etc, daemon-reload, restart, then copy to /srv and
# commit", and each of those minutes was a WARNING the weekend report counted.
# Now each drifted unit is dated by the newer mtime of its two copies (an
# unbacked unit by its /etc copy), the collector reports the oldest, and:
#
#   OK        no drift, or every drifted unit younger than WARN (4h)
#   WARNING   any drifted unit older than WARN
#   UNKNOWN   the collector could not be run, or answered garbage
#
# WARN is an env override in seconds, the same knob check_git_drift.sh has. A
# collector too old to report unit_drift_since counts as aged: WARNING at once,
# the pre-7.0.0 behaviour.

# HOW IT MEASURES (changed under RT #1477): same collector, same privilege
# split, as check_git_drift.sh -- see that header. UNKNOWN now means the
# collector could not be run, not that a timer died.

set -uo pipefail

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/srv-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
WARN=${WARN:-14400}

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3
dur() { if [ "$1" -ge 3600 ]; then echo "$(( $1 / 3600 ))h"; else echo "$(( $1 / 60 ))m"; fi; }

raw=$("$EXEC" "$CONTAINER" "$COLLECT" 2>/dev/null)
rc=$?

[ "$rc" -eq 0 ] || { echo "UNIT DRIFT UNKNOWN - collector exec in $CONTAINER exited $rc"; exit $UNKNOWN; }

field() { printf '%s\n' "$raw" | grep -m1 -oE "SRVDRIFT $1=.*" | cut -d= -f2- ; }

[ -n "$(field end)" ] || { echo "UNIT DRIFT UNKNOWN - collector output truncated or unrecognised"; exit $UNKNOWN; }

error=$(field error)
[ -n "$error" ] && { echo "UNIT DRIFT UNKNOWN - collector reported: $error"; exit $UNKNOWN; }

unit_mismatch=$(field unit_mismatch)
unit_unbacked=$(field unit_unbacked)
unit_list=$(field unit_list)
since=$(field unit_drift_since)
case "$since" in ''|*[!0-9]*) since=0 ;; esac

for v in "$unit_mismatch" "$unit_unbacked"; do
  case "$v" in ''|*[!0-9]*) echo "UNIT DRIFT UNKNOWN - collector returned a non-numeric count"; exit $UNKNOWN ;; esac
done

total=$(( unit_mismatch + unit_unbacked ))
perf="mismatch=${unit_mismatch};1;;0 unbacked=${unit_unbacked};1;;0"

if [ "$total" -eq 0 ]; then
  echo "UNIT DRIFT OK - every running unit matches its /srv copy | $perf"
  exit $OK
fi

parts=""
[ "$unit_mismatch" -gt 0 ] && parts="${unit_mismatch} unit(s) differ from /srv"
[ "$unit_unbacked" -gt 0 ] && parts="${parts:+$parts, }${unit_unbacked} unit(s) have no /srv copy"
[ -n "$unit_list" ] && parts="$parts (${unit_list})"

now=$(date +%s)
if [ "$since" -gt 0 ]; then age=$(( now - since )); else age=$WARN; fi
[ "$age" -lt 0 ] && age=0
perf="$perf drift_age=${age}s;${WARN};;0"

if [ "$age" -lt "$WARN" ]; then
  echo "UNIT DRIFT OK - drift $(dur "$age"), within grace (warn after $(dur "$WARN")): $parts | $perf"
  exit $OK
fi
echo "UNIT DRIFT WARNING - drift $(dur "$age"): $parts | $perf"
exit $WARNING
