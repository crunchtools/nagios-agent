#!/bin/bash
# selinux-drift-collect.sh — compare the host's live SELinux customizations
# with the git-tracked export in /srv (RT #1546)
#
# RHEL keeps local booleans, ports and file-context rules in /var/lib/selinux,
# which neither pbs's /etc backup nor bootc's /etc merge covers. Hand fixes
# made that way on lotor were lost when gloval was restored. The host now
# applies /srv/selinux-local/config/local.semanage at boot
# (selinux-local.service), and this measures whether the live state still
# matches it.
#
# WHO RUNS THIS. check_selinux_drift.sh shells back through podman_exec.sh to
# run this as root in the privileged host agent, the same split as
# srv-drift-collect.sh: semanage needs root, and the host's policy store is
# only reachable by entering PID 1's mount namespace.
#
# WHAT CROSSES THE BOUNDARY. Counts and the kind and name of each differing
# entry ("boolean virt_use_nfs"), never whole lines.
#
# OUTPUT. One "SELINUXDRIFT key=value" line per field, ending with
# SELINUXDRIFT end=1 (see srv-drift-collect.sh for why).

set -uo pipefail

FILE=${FILE:-/var/srv/selinux-local/config/local.semanage}
SEMANAGE=${SEMANAGE:-nsenter -t 1 -m -- /usr/sbin/semanage}

emit() { printf 'SELINUXDRIFT %s=%s\n' "$1" "$2"; }

if [ ! -r "$FILE" ]; then
  emit file missing
  emit end 1
  exit 0
fi

# $SEMANAGE is a command line, so it is split on purpose.
# shellcheck disable=SC2086
if ! live=$($SEMANAGE export 2>/dev/null) || [ -z "$live" ]; then
  emit error "semanage export failed"
  emit end 1
  exit 0
fi

# "boolean -m -1 virt_use_nfs" -> "boolean virt_use_nfs". "-D" lines carry no
# name, and blank lines (an empty side's printf) are not settings.
names() { awk 'NF && $2 != "-D" { print $1, $NF }' | tr -d "'" | sort -u; }

live_sorted=$(printf '%s\n' "$live" | sort -u)
file_sorted=$(sort -u "$FILE")
only_live=$(comm -23 <(printf '%s\n' "$live_sorted") <(printf '%s\n' "$file_sorted") | names)
only_file=$(comm -13 <(printf '%s\n' "$live_sorted") <(printf '%s\n' "$file_sorted") | names)

count() { [ -n "$1" ] && printf '%s\n' "$1" | wc -l || echo 0; }

emit file present
emit live_only "$(count "$only_live")"
emit file_only "$(count "$only_file")"
emit list "$(printf '%s\n%s\n' "$only_live" "$only_file" | sed '/^$/d' | sort -u | head -5 | paste -sd ',' -)"
emit end 1
