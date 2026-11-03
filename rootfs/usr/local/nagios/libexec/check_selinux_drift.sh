#!/bin/bash
# check_selinux_drift.sh — alert when the host's local SELinux customizations
# differ from /srv/selinux-local/config/local.semanage (RT #1546)
#
# A boolean flipped or a port added by hand works until the next restore,
# then silently goes missing: that is how gloval lost lotor's
# systemd_socket_proxyd booleans and the dev site's socket broke. This makes
# the hand change visible while whoever made it still remembers why.
#
#   OK        live state matches the file
#   WARNING   they differ, or the file is missing
#   UNKNOWN   the collector could not be run, or answered garbage
#
# The fix is one of: `semanage export > /srv/selinux-local/config/local.semanage`
# and commit (keep the change), or `systemctl restart selinux-local` (undo it).
#
# Same collector split as check_unit_drift.sh: selinux-drift-collect.sh runs as
# root in the agent container via podman_exec.sh.

set -uo pipefail

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/selinux-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}

OK=0; WARNING=1; UNKNOWN=3

raw=$("$EXEC" "$CONTAINER" "$COLLECT" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || { echo "SELINUX DRIFT UNKNOWN - collector exec in $CONTAINER exited $rc"; exit $UNKNOWN; }

field() { printf '%s\n' "$raw" | grep -m1 -oE "SELINUXDRIFT $1=.*" | cut -d= -f2- ; }

[ -n "$(field end)" ] || { echo "SELINUX DRIFT UNKNOWN - collector output truncated or unrecognised"; exit $UNKNOWN; }

error=$(field error)
[ -n "$error" ] && { echo "SELINUX DRIFT UNKNOWN - collector reported: $error"; exit $UNKNOWN; }

if [ "$(field file)" = missing ]; then
  echo "SELINUX DRIFT WARNING - /srv/selinux-local/config/local.semanage is missing: nothing re-applies local SELinux settings after a restore"
  exit $WARNING
fi

live_only=$(field live_only)
file_only=$(field file_only)
for v in "$live_only" "$file_only"; do
  case "$v" in ''|*[!0-9]*) echo "SELINUX DRIFT UNKNOWN - collector returned a non-numeric count"; exit $UNKNOWN ;; esac
done

perf="live_only=${live_only};1;;0 file_only=${file_only};1;;0"
if [ $(( live_only + file_only )) -eq 0 ]; then
  echo "SELINUX DRIFT OK - live customizations match /srv | $perf"
  exit $OK
fi
echo "SELINUX DRIFT WARNING - ${live_only} live setting(s) not in /srv, ${file_only} in /srv not live ($(field list)) | $perf"
exit $WARNING
