#!/bin/bash
# srv-drift-collect.sh — measure /srv config drift from inside the agent container (RT #1477)
#
# Replaces the root srv-git-drift.timer collector that RT #1466 had to ship
# because the agent image had no git. It does now, so the measurement moved
# into the container and the timer is gone: scheduled work lives in Nagios or
# Hermes, never in a bespoke timer nobody watches.
#
# WHO RUNS THIS. Not nrpe. The plugins (check_git_drift.sh, check_unit_drift.sh)
# run unprivileged and shell back through podman_exec.sh to run this script as
# root in this same container. That looks like a detour and is not:
# /var/srv/newsletter.crunchtools.com/certbot/config/archive is 0700 root, and
# git walking it as nrpe dies with "Permission denied" and exit 141. The
# split is load-bearing. Do not "simplify" it into a direct call.
#
# WHAT CROSSES THE BOUNDARY. Counts, timestamps, and top-level directory or
# unit names only — never file contents. /var/srv holds ~25 .env files and
# several private keys, and the same rule that governed the old status file
# governs this stdout.
#
# OUTPUT. One "SRVDRIFT key=value" line per field, ending with SRVDRIFT end=1.
# The sentinel and the end marker are deliberate: podman_exec.sh strips the
# libpod stream framing byte-wise, and a frame header's length bytes can
# survive as a stray printable character. Anchoring each field to a sentinel
# keeps one stray byte from corrupting a parse, and end=1 proves the output
# was not truncated mid-stream.
#
# No `git fetch`: lotor is the only writer, so the local origin/master ref
# answers "have I pushed?" without putting SSH in a monitoring path.

set -uo pipefail

REPO=${REPO:-/var/srv}
UNITS=${UNITS:-/etc/systemd/system}
NOW=$(date +%s)

emit() { printf 'SRVDRIFT %s=%s\n' "$1" "$2"; }

bail() {
  emit generated "$NOW"
  emit error "$1"
  emit end 1
  exit 0
}

command -v git >/dev/null 2>&1 || bail git_missing
[ -d "$REPO/.git" ] || bail repo_not_mounted
[ -d "$UNITS" ]     || bail units_not_mounted

cd "$REPO" || bail repo_unreadable

# --no-optional-locks: the tree is mounted read-only, so git must not try to
# refresh and rewrite .git/index while we are only asking a question.
porcelain=$(git --no-optional-locks status --porcelain -uall 2>/dev/null) || bail git_status_failed

dirty_files=$(printf %s "$porcelain" | grep -c .)
unpushed=$(git --no-optional-locks rev-list --count origin/master..HEAD 2>/dev/null || echo 0)

# Oldest evidence of drift, so the age reflects when config actually changed
# rather than when this check first noticed. The old collector kept a marker
# file for this; measuring mtimes directly is stateless and survives a restart.
oldest=0
if [ "$dirty_files" -gt 0 ]; then
  while read -r _ path; do
    [ -n "$path" ] || continue
    if [ -e "$path" ]; then
      m=$(stat -c %Y -- "$path" 2>/dev/null) || continue
    else
      # A deletion leaves no mtime to read, but it bumped the parent directory.
      m=$(stat -c %Y -- "$(dirname -- "$path")" 2>/dev/null) || continue
    fi
    { [ "$oldest" -eq 0 ] || [ "$m" -lt "$oldest" ]; } && oldest=$m
  done <<< "$porcelain"
fi
if [ "$unpushed" -gt 0 ]; then
  c=$(git --no-optional-locks log --format=%ct origin/master..HEAD 2>/dev/null | tail -1)
  [ -n "$c" ] && { [ "$oldest" -eq 0 ] || [ "$c" -lt "$oldest" ]; } && oldest=$c
fi

if [ "$dirty_files" -eq 0 ] && [ "$unpushed" -eq 0 ]; then
  drift_since=0
else
  drift_since=${oldest:-$NOW}
  [ "$drift_since" -eq 0 ] && drift_since=$NOW
fi

# --- Second door: /etc vs /srv (RT #1466) ---
# The git half above guards /srv -> git. It cannot see a unit edited directly
# in /etc/systemd/system and never written back: /srv still matches git, so
# everything reads clean while git holds a definition that would break the
# service if restored. 11 units had drifted that way and 38 more ran with no
# /srv copy at all. Only units mentioning /srv are ours to police; OS units
# (dbus, bluez) are not.
unit_mismatch=0
unit_unbacked=0
unit_list=""

for src in "$REPO"/*/config/*.service "$REPO"/*/config/*.timer; do
  [ -f "$src" ] || continue
  base=$(basename "$src")
  inst="$UNITS/$base"
  [ -f "$inst" ] || continue
  cmp -s "$src" "$inst" && continue
  unit_mismatch=$(( unit_mismatch + 1 ))
  unit_list="${unit_list:+$unit_list,}$base"
done

for inst in "$UNITS"/*.service "$UNITS"/*.timer; do
  [ -f "$inst" ] || continue
  grep -q /srv "$inst" 2>/dev/null || continue
  base=$(basename "$inst")
  found=0
  for c in "$REPO"/*/config/"$base"; do [ -f "$c" ] && found=1; done
  [ "$found" -eq 1 ] && continue
  unit_unbacked=$(( unit_unbacked + 1 ))
  unit_list="${unit_list:+$unit_list,}$base"
done

unit_list=$(printf %s "$unit_list" | cut -c1-200)
services=$(printf %s "$porcelain" | awk '{print $NF}' | cut -d/ -f1 | sort -u | head -6 | paste -sd, -)

emit generated     "$NOW"
emit dirty_files   "$dirty_files"
emit unpushed      "$unpushed"
emit drift_since   "$drift_since"
emit services      "$services"
emit unit_mismatch "$unit_mismatch"
emit unit_unbacked "$unit_unbacked"
emit unit_list     "$unit_list"
emit end 1
