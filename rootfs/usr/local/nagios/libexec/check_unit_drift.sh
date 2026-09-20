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
# No time threshold. Unlike uncommitted edits there is no benign window here:
# a running unit that does not match its backup is wrong the moment it happens,
# and WARNING notifies nobody (hermes is CRITICAL-only), so it costs nothing.
#
# HOW IT MEASURES (changed under RT #1477): same collector, same privilege
# split, as check_git_drift.sh -- see that header. UNKNOWN now means the
# collector could not be run, not that a timer died.

set -uo pipefail

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/srv-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

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

echo "UNIT DRIFT WARNING - $parts | $perf"
exit $WARNING
