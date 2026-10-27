#!/bin/bash
# check_backup_freshness.sh — pCloud server backup freshness for lotor (Nagios/NRPE)
#
# Judges the status file backup-freshness-collect.sh writes; never touches
# pCloud itself (7.0.0). Listing 19 sentinels live inside NRPE's 15s
# command_timeout kept timing out on slow pCloud reads while every backup was
# fine (11 UNKNOWNs in 48h), so the reads moved to the collector, which has a
# 120s budget. See that script's header for the file format.
#
# The collector is started from here: when the status file is missing or older
# than REFRESH (20m), this plugin launches it detached through
# `podman_exec.sh --detach` in nagios-agent.crunchtools.com and judges the file
# the previous run wrote. The Nagios check_interval (30m) is the clock.
#
# Verdicts, per sentinel, the same thresholds as before the split:
#   Weekly-1   WARNING 9d,  CRITICAL 16d   (pbs Servers syncs Saturdays 04:00)
#   Monthly-*  WARNING 70d, CRITICAL 100d  (the two rotations alternate months)
#   CRITICAL   dump missing (rclone exit 3/4 or an empty listing), or below its
#              size floor
#   UNKNOWN    the status file is missing or older than STALE (2h): "collector
#              stale"; or one sentinel pCloud has not answered for in STALE
#              (the collector keeps the last real answer through a timeout)
# Status precedence is OK < WARNING < UNKNOWN < CRITICAL, and the first line
# names the worst sentinel: notifications only carry that line.

STATE_DIR=${STATE_DIR:-/var/lib/nagios-agent}
STATUS=${STATUS:-$STATE_DIR/backup-freshness.status}
EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/backup-freshness-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
REFRESH=${REFRESH:-1200}   # seconds: start a collector run when the file is this old
STALE=${STALE:-7200}       # seconds: older than this and the data is not trusted
NOW=$(date +%s)

W_WARN=9  W_CRIT=16    # days
M_WARN=70 M_CRIT=100   # days

kick() { "$EXEC" --detach "$CONTAINER" "$COLLECT" servers >/dev/null 2>&1; }

if [ ! -r "$STATUS" ]; then
    kick && started="collector started" || started="collector could not be started"
    echo "BACKUPS UNKNOWN - collector stale: no status file at $STATUS ($started)"
    exit 3
fi

raw=$(cat "$STATUS")
generated=$(grep -m1 -oE '^BKUP generated=[0-9]+' <<< "$raw" | cut -d= -f2)
grep -qx 'BKUP end=1' <<< "$raw" || generated=""
if [ -z "$generated" ]; then
    kick
    echo "BACKUPS UNKNOWN - collector stale: $STATUS is truncated or unrecognised"
    exit 3
fi
collected=$((NOW - generated))
kicked=""
if [ "$collected" -ge "$REFRESH" ]; then kick || kicked=" (collector could not be started)"; fi
if [ "$collected" -ge "$STALE" ]; then
    echo "BACKUPS UNKNOWN - collector stale: last collection $((collected / 3600))h$(( collected % 3600 / 60 ))m ago${kicked} | collected_age=${collected}s;;${STALE}"
    exit 3
fi
elapsed=$(grep -m1 -oE '^BKUP generated=[0-9]+ elapsed=[0-9]+' <<< "$raw" | grep -oE '[0-9]+$')

# Results carry a rank, not a Nagios code, so they sort by severity:
# 0 OK, 1 WARNING, 2 UNCHECKED, 3 UNKNOWN, 4 CRITICAL. UNCHECKED ranks below
# UNKNOWN so a real timeout or rclone error is what the first line names.
R_OK=0 R_WARN=1 R_UNCHECKED=2 R_UNKNOWN=3 R_CRIT=4

field() { grep -oE "(^| )$1=[^ ]*" <<< "$2" | head -1 | cut -d= -f2; }

items=0; worst=$R_OK; problems=""; unknown=0; w_total=0; w_ok=0; w_worst=0; m1_age=-1; m2_age=-1
while IFS= read -r line; do
    label=$(field item "$line"); rot=$(field rot "$line"); seen=$(field seen "$line")
    result=$(field result "$line"); floor=$(field floor "$line")
    [ -n "$label" ] || continue
    items=$((items + 1))
    if [ "$rot" = Weekly-1 ]; then warn=$W_WARN crit=$W_CRIT; else warn=$M_WARN crit=$M_CRIT; fi
    age=-1
    case "$result" in
        ok)
            epoch=$(field epoch "$line"); size=$(field size "$line")
            age=$(( (NOW - epoch) / 86400 ))
            rank=$R_OK; msg="$label: ${age}d"
            if   [ "$age" -ge "$crit" ]; then rank=$R_CRIT; msg="$label: STALE ${age}d (crit ${crit}d)"
            elif [ "$age" -ge "$warn" ]; then rank=$R_WARN; msg="$label: aging ${age}d (warn ${warn}d)"
            fi
            if [ "$size" -lt "$floor" ] 2>/dev/null; then
                rank=$R_CRIT; msg="$label: TOO SMALL ${size}B (floor ${floor}B), age ${age}d"
            fi ;;
        missing)   rank=$R_CRIT;      msg="$label: MISSING ($(field path "$line"))" ;;
        unchecked) rank=$R_UNCHECKED; msg=${line#* msg=} ;;
        *)         rank=$R_UNKNOWN;   msg=${line#* msg=} ;;
    esac
    # A sentinel pCloud has not answered for in STALE is not judged on old news,
    # but a CRITICAL it already showed stays CRITICAL: the dump did not heal.
    if [ "$rank" -lt "$R_CRIT" ] && [ $((NOW - ${seen:-0})) -ge "$STALE" ]; then
        rank=$R_UNKNOWN; msg="$label: not read from pCloud for $(( (NOW - ${seen:-0}) / 3600 ))h (last: ${msg#"$label: "})"
    fi
    [ "$rank" -gt "$worst" ] && worst=$rank
    [ "$rank" -eq "$R_UNCHECKED" ] || [ "$rank" -eq "$R_UNKNOWN" ] && unknown=$((unknown+1))
    case "$rot" in
        Weekly-1)  w_total=$((w_total+1)); [ "$rank" -eq "$R_OK" ] && w_ok=$((w_ok+1))
                   [ "$age" -gt "$w_worst" ] && w_worst=$age ;;
        Monthly-1) [ "$age" -gt "$m1_age" ] && m1_age=$age ;;
        Monthly-2) [ "$age" -gt "$m2_age" ] && m2_age=$age ;;
    esac
    [ "$rank" -ne "$R_OK" ] && problems+="$rank|$msg"$'\n'
done < <(grep -E '^BKUP item=' <<< "$raw")

if [ "$items" -eq 0 ]; then
    echo "BACKUPS UNKNOWN - collector stale: $STATUS holds no sentinels"
    exit 3
fi

problems=$(sort -s -t'|' -k1,1nr <<< "${problems%$'\n'}" | cut -d'|' -f2-)
count=0; [ -n "$problems" ] && count=$(wc -l <<< "$problems")

case $worst in
    "$R_OK")   word=OK;       status=0 ;;
    "$R_WARN") word=WARNING;  status=1 ;;
    "$R_CRIT") word=CRITICAL; status=2 ;;
    *)         word=UNKNOWN;  status=3 ;;
esac
head=""
if [ "$count" -gt 0 ]; then
    head="$(head -1 <<< "$problems")"
    [ "$count" -gt 1 ] && head+=" [+$((count - 1)) more]"
    head+="; "
fi
unchecked=""; [ "$unknown" -gt 0 ] && unchecked=", $unknown unchecked"
days() { [ "$1" -ge 0 ] && echo "${1}d" || echo "?"; }
perf="weekly_worst_age=${w_worst}d;$W_WARN;$W_CRIT monthly1_age=${m1_age}d;$M_WARN;$M_CRIT monthly2_age=${m2_age}d;$M_WARN;$M_CRIT stale=${count} unknown=${unknown} elapsed=${elapsed:-0}s collected_age=${collected}s;;${STALE}"
echo "BACKUPS $word - ${head}Weekly-1 ${w_ok}/${w_total} fresh (worst ${w_worst}d)${unchecked}; Monthly-1 $(days "$m1_age"); Monthly-2 $(days "$m2_age")${kicked} | $perf"
[ -n "$problems" ] && echo "$problems"
exit $status
