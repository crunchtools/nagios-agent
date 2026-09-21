#!/bin/bash
# srv-nightly-dump-collect.sh — age of each in-container nightly DB dump (RT #1497)
#
# THE GAP THIS CLOSES. Three services dump their own database from a cron or
# timer *inside their own container*, on top of the weekly pbs dump:
#
#   learn.fatherlinux.com    my_wiki.sql + export.xml   nightly
#   rt.fatherlinux.com       rt4.sql                    nightly
#   postiz.crunchtools.com   postiz-*.sql.gz            nightly
#
# check_backup_freshness.sh already watches the pCloud copies, but pCloud only
# refreshes on the Saturday sync, so a nightly job that dies mid-week is invisible
# for up to seven days while its sentinel stays green. This reads the dumps where
# they land first — on disk under /var/srv — so a dead cron shows the next morning.
#
# WHO RUNS THIS. Not nrpe. check_nightly_dump.sh runs unprivileged and shells
# back through podman_exec.sh to run this as root in this same container, exactly
# like srv-drift-collect.sh. The split is load-bearing: postiz writes its dump
# 0600 in a 0700 dir (it plausibly holds social OAuth tokens), so nrpe cannot
# stat it and loosening the mode is the wrong fix. Root reads it without touching
# the perms. /var/srv is already ro-mounted for the drift checks — no new mount.
#
# WHAT CROSSES THE BOUNDARY. A label, an mtime, a size and a size floor per
# service — never a byte of dump content. Same rule that governs srv-drift-collect.
#
# OUTPUT. One "NDUMP item=<label> epoch=<m> size=<s> floor=<min>" line per
# sentinel, ending with NDUMP end=1. epoch=0 means the dump is missing or
# unreadable. The sentinel prefix and end marker are deliberate: podman_exec.sh
# strips the libpod stream framing byte-wise and a stray length byte can survive
# as a printable char, so each line is self-anchored and end=1 proves the stream
# was not truncated. All policy (age thresholds, verdict) lives in the plugin;
# this script only reports facts.

set -uo pipefail

BASE=${BASE:-/var/srv}
NOW=$(date +%s)

# label|dir (under BASE)|glob|min_bytes
#   dir is service-relative so a test can repoint BASE; glob picks the newest
#   match by mtime, so an old *_pre_upgrade.sql never masks a dead nightly job.
SENTINELS="
learn_wiki|learn.fatherlinux.com/data/backups|my_wiki.sql|100000000
learn_export|learn.fatherlinux.com/data/backups|export.xml|100000000
rt|rt.fatherlinux.com/data/backups|rt4.sql|15000000
postiz|postiz.crunchtools.com/data/backups|postiz-*.sql.gz|50000
"

emit() { printf 'NDUMP %s\n' "$1"; }

bail() {
  emit "generated=$NOW"
  emit "error=$1"
  emit "end=1"
  exit 0
}

[ -d "$BASE" ] || bail base_not_mounted

emit "generated=$NOW"

while IFS='|' read -r label rel glob min; do
  [ -z "$label" ] && continue
  dir="$BASE/$rel"
  newest=""; newest_m=0
  # Word-split the glob deliberately; nullglob is not set, so an unmatched
  # pattern yields the literal string, which [ -e ] then rejects.
  for f in "$dir"/$glob; do
    [ -e "$f" ] || continue
    m=$(stat -c %Y -- "$f" 2>/dev/null) || continue
    if [ "$m" -gt "$newest_m" ]; then newest="$f"; newest_m=$m; fi
  done
  if [ -z "$newest" ]; then
    emit "item=$label epoch=0 size=0 floor=$min"
  else
    size=$(stat -c %s -- "$newest" 2>/dev/null || echo 0)
    emit "item=$label epoch=$newest_m size=$size floor=$min"
  fi
done <<< "$SENTINELS"

emit "end=1"
