#!/bin/bash
# check_nightly_dump.sh — freshness of in-container nightly DB dumps (RT #1497)
#
# The counterpart to check_backup_freshness.sh. That one watches the weekly
# pCloud copies; this one watches the nightly dumps where they land first, on
# disk under /var/srv, so a nightly cron or timer that dies mid-week is caught
# the next morning instead of staying hidden behind a green pCloud sentinel for
# up to seven days (the pCloud copy only refreshes on the Saturday sync).
#
# HOW IT MEASURES. Like check_git_drift.sh, nrpe never reads /var/srv itself: it
# asks podman to run srv-nightly-dump-collect.sh as root in this same container
# and parses the answer. That split exists because postiz writes its dump 0600 in
# a 0700 dir and nrpe cannot stat it. The collector reports only a label, mtime,
# size and floor per service; this plugin holds all the policy.
#
#   WARNING   dump older than 36h  — one missed night plus margin
#   CRITICAL  dump older than 50h  — two missed nights; or missing; or a dump
#                                    that ran but came out below its size floor
#   UNKNOWN   the collector could not be run, or answered garbage
#
# Nightly cadence, so a WARNING already means last night's job did not run. The
# floor catches the other failure: a dump that exits 0 but writes near-empty.

set -uo pipefail

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/srv-nightly-dump-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
WARN=${WARN:-129600}   # 36h in seconds
CRIT=${CRIT:-180000}   # 50h in seconds

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

raw=$("$EXEC" "$CONTAINER" "$COLLECT" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || { echo "NIGHTLY DUMP UNKNOWN - collector exec in $CONTAINER exited $rc"; exit $UNKNOWN; }

# Anchored extraction, not a line parse: podman_exec.sh strips the libpod stream
# framing byte-wise and a stray printable byte can survive it.
sentinel() { printf '%s\n' "$raw" | grep -m1 -oE "NDUMP $1(=.*)?" ; }

[ -n "$(sentinel end)" ] || { echo "NIGHTLY DUMP UNKNOWN - collector output truncated or unrecognised"; exit $UNKNOWN; }

error=$(printf '%s\n' "$raw" | grep -m1 -oE 'NDUMP error=.*' | cut -d= -f2-)
[ -n "$error" ] && { echo "NIGHTLY DUMP UNKNOWN - collector reported: $error"; exit $UNKNOWN; }

# One self-anchored line per service; a stray byte can only corrupt its own item.
items=$(printf '%s\n' "$raw" | grep -oE 'NDUMP item=[a-z_]+ epoch=[0-9]+ size=[0-9]+ floor=[0-9]+')
[ -n "$items" ] || { echo "NIGHTLY DUMP UNKNOWN - collector returned no dump items"; exit $UNKNOWN; }

now=$(date +%s)
status=$OK; problems=(); perf=""; oldest_label=""; oldest_age=-1

while read -r _ litem lepoch lsize lfloor; do
  [ -n "$litem" ] || continue
  label=${litem#item=}; epoch=${lepoch#epoch=}; size=${lsize#size=}; floor=${lfloor#floor=}

  if [ "$epoch" -eq 0 ]; then
    status=$CRITICAL; problems+=("$label: MISSING (no readable dump)")
    perf="${perf:+$perf }${label}_age=U"
    continue
  fi

  age=$(( now - epoch ))
  perf="${perf:+$perf }${label}_age=${age}s;${WARN};${CRIT};0"
  [ "$age" -gt "$oldest_age" ] && { oldest_age=$age; oldest_label=$label; }

  st=$OK; msg=""
  if   [ "$age" -ge "$CRIT" ]; then st=$CRITICAL; msg="$label: STALE $(( age / 3600 ))h (crit $(( CRIT / 3600 ))h)"
  elif [ "$age" -ge "$WARN" ]; then st=$WARNING;  msg="$label: aging $(( age / 3600 ))h (warn $(( WARN / 3600 ))h)"
  fi
  # Floor trumps age: a fresh dump that came out too small is a worse signal
  # than a slightly old one.
  if [ "$size" -lt "$floor" ]; then st=$CRITICAL; msg="$label: TOO SMALL ${size}B (floor ${floor}B), age $(( age / 3600 ))h"; fi

  [ "$st" -gt "$status" ] && status=$st
  [ -n "$msg" ] && problems+=("$msg")
done <<< "$items"

perf="$perf stale=${#problems[@]}"

case $status in
  "$OK")       echo "NIGHTLY DUMP OK - all dumps fresh (oldest ${oldest_label} $(( oldest_age / 3600 ))h) | $perf"; exit $OK ;;
  "$WARNING")  word=WARNING; rc=$WARNING ;;
  *)           word=CRITICAL; rc=$CRITICAL ;;
esac

echo "NIGHTLY DUMP $word - ${problems[0]} | $perf"
for p in "${problems[@]:1}"; do echo "$p"; done
exit $rc
