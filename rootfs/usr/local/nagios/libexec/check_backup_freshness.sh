#!/bin/bash
# check_backup_freshness.sh — live pCloud backup freshness for lotor (Nagios/NRPE)
#
# Every check hits pCloud live — no state files, no timers. Each sentinel is one
# small rclone listing; all run in parallel, keeping wall time ~2-4s, inside the
# agent's deliberately short command_timeout=15.
#
# Weekly-1 sentinels: one dump file (or newest .db in a data dir) per service,
# judged on age and a size floor — a dump that shrinks below the floor is as
# suspect as a missing one. Monthly-1/2 alternate months (~61d cadence), proxied
# by two representative dumps each with 70/100-day thresholds.
#
# rclone and its config are ro-mounted from the host into the agent container
# (see the nagios-agent unit); runs unprivileged as the nrpe user.
# Decommissioned services (openclaw, zabbix) are deliberately absent.

RCLONE=${RCLONE:-/usr/local/bin/rclone}
CONF=${CONF:-/etc/nagios/rclone.conf}
BASE=pcloud:Backups/Servers/lotor.dc3.crunchtools.com
NOW=$(date +%s)
TMP=$(mktemp -d) || { echo "UNKNOWN - mktemp failed"; exit 3; }
trap 'rm -rf "$TMP"' EXIT

[ -x "$RCLONE" ] || { echo "UNKNOWN - $RCLONE not mounted into agent container"; exit 3; }
[ -r "$CONF" ]   || { echo "UNKNOWN - $CONF not readable"; exit 3; }

W_WARN=9  W_CRIT=16    # days — Weekly-1 syncs Saturdays 04:00
M_WARN=70 M_CRIT=100   # days — each monthly rotation fires every other month

# label|rotation|warn|crit|min_bytes|mode|path
#   mode=file : path is the exact dump file
#   mode=dir  : newest *.db / *.sqlite* under path (recursive)
SENTINELS="
crunchtools-db|Weekly-1|$W_WARN|$W_CRIT|15000000|file|crunchtools.com/backups/all-databases.sql
educatedconfusion-db|Weekly-1|$W_WARN|$W_CRIT|10000000|file|educatedconfusion.com/backups/all-databases.sql
learn-wiki-db|Weekly-1|$W_WARN|$W_CRIT|100000000|file|learn.fatherlinux.com/data/backups/my_wiki.sql
rt-db|Weekly-1|$W_WARN|$W_CRIT|15000000|file|rt.fatherlinux.com/data/backups/rt4.sql
test-crunchtools-db|Weekly-1|$W_WARN|$W_CRIT|1000000|file|test.crunchtools.com/backups/all-databases.sql
rootsofthevalley-db|Weekly-1|$W_WARN|$W_CRIT|200000000|file|rootsofthevalley.org/backups/all-databases.sql
images-rotv-db|Weekly-1|$W_WARN|$W_CRIT|400000|file|images.rootsofthevalley.org/backups/all-databases.sql
postiz-db|Weekly-1|$W_WARN|$W_CRIT|1000000|file|postiz.crunchtools.com/backups/all-databases.sql
acquacotta-db|Weekly-1|$W_WARN|$W_CRIT|1000|dir|acquacotta.crunchtools.com/data
kagetora-db|Weekly-1|$W_WARN|$W_CRIT|100000|dir|kagetora.crunchtools.com/data
mcp-feeds-db|Weekly-1|$W_WARN|$W_CRIT|30000000|file|mcp-feeds.crunchtools.com/data/feeds.db
mcp-memory-db|Weekly-1|$W_WARN|$W_CRIT|5000000|dir|mcp-memory.crunchtools.com/data
mcp-metsuke-db|Weekly-1|$W_WARN|$W_CRIT|50000|file|mcp-metsuke.crunchtools.com/data/metsuke.db
mcp-trentina-db|Weekly-1|$W_WARN|$W_CRIT|200000|dir|mcp-trentina.crunchtools.com/data
newsletter-db|Weekly-1|$W_WARN|$W_CRIT|1000000|file|newsletter.crunchtools.com/data/kill-the-newsletter.db
monthly1-crunchtools|Monthly-1|$M_WARN|$M_CRIT|15000000|file|crunchtools.com/backups/all-databases.sql
monthly1-rotv|Monthly-1|$M_WARN|$M_CRIT|200000000|file|rootsofthevalley.org/backups/all-databases.sql
monthly2-crunchtools|Monthly-2|$M_WARN|$M_CRIT|15000000|file|crunchtools.com/backups/all-databases.sql
monthly2-rotv|Monthly-2|$M_WARN|$M_CRIT|200000000|file|rootsofthevalley.org/backups/all-databases.sql
"

probe() { # writes: label|rot|status|age_days|size|message  to $TMP/<label>
    local label=$1 rot=$2 warn=$3 crit=$4 min=$5 mode=$6 path=$7 out ts size epoch age st msg
    if [ "$mode" = file ]; then
        out=$(timeout 8 "$RCLONE" --config "$CONF" lsf --files-only \
              --format ts --separator '|' "$BASE/$rot/$path" 2>/dev/null | head -1)
    else
        out=$(timeout 8 "$RCLONE" --config "$CONF" lsf -R --files-only \
              --include '*.db' --include '*.sqlite*' \
              --format ts --separator '|' "$BASE/$rot/$path" 2>/dev/null | sort -r | head -1)
    fi
    if [ -z "$out" ]; then
        echo "$label|$rot|2|-1|0|$label: MISSING ($rot/$path)" > "$TMP/$label"; return
    fi
    ts=${out%%|*}; size=${out##*|}
    epoch=$(date -d "$ts" +%s 2>/dev/null) || {
        echo "$label|$rot|3|-1|0|$label: unparseable mtime '$ts'" > "$TMP/$label"; return; }
    age=$(( (NOW - epoch) / 86400 ))
    st=0; msg="$label: ${age}d"
    if   [ "$age" -ge "$crit" ]; then st=2; msg="$label: STALE ${age}d (crit ${crit}d)"
    elif [ "$age" -ge "$warn" ]; then st=1; msg="$label: aging ${age}d (warn ${warn}d)"
    fi
    if [ "$size" -lt "$min" ] 2>/dev/null; then
        st=2; msg="$label: TOO SMALL ${size}B (floor ${min}B), age ${age}d"
    fi
    echo "$label|$rot|$st|$age|$size|$msg" > "$TMP/$label"
}

# Waves of 7: each rclone process costs ~40-60MB and the agent container is
# memory-capped, so unbounded parallelism gets the probes OOM-killed.
n=0
while IFS='|' read -r label rot warn crit min mode path; do
    [ -z "$label" ] && continue
    probe "$label" "$rot" "$warn" "$crit" "$min" "$mode" "$path" &
    n=$((n+1)); [ $((n % 7)) -eq 0 ] && wait
done <<< "$SENTINELS"
wait

status=0; problems=(); w_total=0; w_ok=0; w_worst=0; m1_age=-1; m2_age=-1
for f in "$TMP"/*; do
    IFS='|' read -r label rot st age size msg < "$f"
    [ "$st" -gt "$status" ] && status=$st
    case "$rot" in
        Weekly-1)  w_total=$((w_total+1)); [ "$st" -eq 0 ] && w_ok=$((w_ok+1))
                   [ "$age" -gt "$w_worst" ] && w_worst=$age ;;
        Monthly-1) [ "$age" -gt "$m1_age" ] && m1_age=$age ;;
        Monthly-2) [ "$age" -gt "$m2_age" ] && m2_age=$age ;;
    esac
    [ "$st" -ne 0 ] && problems+=("$msg")
done

case $status in 0) word=OK;; 1) word=WARNING;; 2) word=CRITICAL;; *) word=UNKNOWN;; esac
perf="weekly_worst_age=${w_worst}d;$W_WARN;$W_CRIT monthly1_age=${m1_age}d;$M_WARN;$M_CRIT monthly2_age=${m2_age}d;$M_WARN;$M_CRIT stale=${#problems[@]}"
echo "BACKUPS $word - Weekly-1 ${w_ok}/${w_total} dumps fresh (worst ${w_worst}d); Monthly-1 ${m1_age}d; Monthly-2 ${m2_age}d | $perf"
for p in "${problems[@]}"; do echo "$p"; done
exit $status
