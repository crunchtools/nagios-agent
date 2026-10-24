#!/bin/bash
# check_backup_freshness.sh — live pCloud backup freshness for lotor (Nagios/NRPE)
#
# Every check hits pCloud live — no state files, no timers. Each sentinel is one
# small rclone listing, run in waves of 7. pCloud listings are usually ~1-3s but
# sometimes hang, so the whole run lives inside a global deadline (BUDGET, 12s)
# that stays under the agent's command_timeout=15: each listing gets at most
# PROBE_T seconds (6) or whatever the deadline leaves, and a sentinel reached
# with under 2s left is reported UNCHECKED instead of being started.
#
# rclone's exit code decides what an empty listing means, never the output alone:
#   0 with a file   judged on age and size floor
#   0 empty, 3, 4   CRITICAL MISSING (directory or file not found)
#   124             timed out: one retry if >=3s remain, else UNKNOWN TIMEOUT
#   anything else   one retry if >=3s remain, else UNKNOWN RCLONE ERROR
# Status precedence is OK < WARNING < UNKNOWN < CRITICAL, and the first line
# names the worst sentinel: notifications only carry that line.
#
# Weekly-1 sentinels: one dump file (or newest .db in a data dir) per service,
# judged on age and a size floor — a dump that shrinks below the floor is as
# suspect as a missing one. Monthly-1/2 alternate months (~61d cadence), proxied
# by two representative dumps each with 70/100-day thresholds. The .sql dumps
# never exist on lotor's disk: pbs writes them inside its container and copies
# them straight to pCloud.
#
# rclone and its config are ro-mounted from the host into the agent container
# (see the nagios-agent unit); runs unprivileged as the nrpe user.
# Decommissioned services (openclaw, zabbix) are deliberately absent.

RCLONE=${RCLONE:-/usr/local/bin/rclone}
CONF=${CONF:-/etc/nagios/rclone.conf}
BASE=pcloud:Backups/Servers/lotor.dc3.crunchtools.com
BUDGET=${BUDGET:-12}    # seconds for the whole run
PROBE_T=${PROBE_T:-6}   # seconds per listing
START=$(date +%s)
DEADLINE=$((START + BUDGET))
TMP=$(mktemp -d) || { echo "UNKNOWN - mktemp failed"; exit 3; }
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/res" "$TMP/err"

[ -x "$RCLONE" ] || { echo "UNKNOWN - $RCLONE not mounted into agent container"; exit 3; }
[ -r "$CONF" ]   || { echo "UNKNOWN - $CONF not readable"; exit 3; }

W_WARN=9  W_CRIT=16    # days — Weekly-1 syncs Saturdays 04:00
M_WARN=70 M_CRIT=100   # days — each monthly rotation fires every other month

# label|rotation|warn|crit|min_bytes|mode|path
#   mode=file : path is the exact dump file
#   mode=dir  : newest *.db / *.sqlite* under path (recursive); ties go to the largest
SENTINELS="
crunchtools-db|Weekly-1|$W_WARN|$W_CRIT|15000000|file|crunchtools.com/backups/all-databases.sql
educatedconfusion-db|Weekly-1|$W_WARN|$W_CRIT|10000000|file|educatedconfusion.com/backups/all-databases.sql
learn-wiki-db|Weekly-1|$W_WARN|$W_CRIT|100000000|file|learn.fatherlinux.com/data/backups/my_wiki.sql
rt-db|Weekly-1|$W_WARN|$W_CRIT|15000000|file|rt.fatherlinux.com/data/backups/rt4.sql
rootsofthevalley-db|Weekly-1|$W_WARN|$W_CRIT|200000000|file|rootsofthevalley.org/backups/all-databases.sql
images-rotv-db|Weekly-1|$W_WARN|$W_CRIT|400000|file|images.rootsofthevalley.org/backups/all-databases.sql
postiz-db|Weekly-1|$W_WARN|$W_CRIT|1000000|file|postiz.crunchtools.com/backups/all-databases.sql
acquacotta-db|Weekly-1|$W_WARN|$W_CRIT|1000|dir|acquacotta.crunchtools.com/data
kagetora-db|Weekly-1|$W_WARN|$W_CRIT|100000|dir|kagetora.crunchtools.com/data
mcp-feeds-db|Weekly-1|$W_WARN|$W_CRIT|30000000|file|mcp-feeds.crunchtools.com/data/feeds.db
mcp-memory-db|Weekly-1|$W_WARN|$W_CRIT|5000000|dir|mcp-memory.crunchtools.com/data
mcp-metsuke-db|Weekly-1|$W_WARN|$W_CRIT|50000|file|mcp-metsuke.crunchtools.com/data/metsuke.db
trentina-db|Weekly-1|$W_WARN|$W_CRIT|200000|dir|trentina.crunchtools.com/data
newsletter-db|Weekly-1|$W_WARN|$W_CRIT|1000000|file|newsletter.crunchtools.com/data/kill-the-newsletter.db
monthly1-crunchtools|Monthly-1|$M_WARN|$M_CRIT|15000000|file|crunchtools.com/backups/all-databases.sql
monthly1-rotv|Monthly-1|$M_WARN|$M_CRIT|200000000|file|rootsofthevalley.org/backups/all-databases.sql
monthly2-crunchtools|Monthly-2|$M_WARN|$M_CRIT|15000000|file|crunchtools.com/backups/all-databases.sql
monthly2-rotv|Monthly-2|$M_WARN|$M_CRIT|200000000|file|rootsofthevalley.org/backups/all-databases.sql
"

# Results carry a rank, not a Nagios code, so they sort by severity:
# 0 OK, 1 WARNING, 2 UNCHECKED, 3 UNKNOWN, 4 CRITICAL. UNCHECKED ranks below
# UNKNOWN so a real timeout or rclone error is what the first line names.
R_OK=0 R_WARN=1 R_UNCHECKED=2 R_UNKNOWN=3 R_CRIT=4

lsf() { # <mode> <path> <secs>: rclone alone, so its exit code reaches the caller
    if [ "$1" = file ]; then
        timeout "$3" "$RCLONE" --config "$CONF" lsf --files-only \
            --format ts --separator '|' "$BASE/$2"
    else
        timeout "$3" "$RCLONE" --config "$CONF" lsf -R --files-only \
            --include '*.db' --include '*.sqlite*' \
            --format ts --separator '|' "$BASE/$2"
    fi
}

probe() { # writes: label|rot|rank|age_days|size|message  to $TMP/res/<label>
    local label=$1 rot=$2 warn=$3 crit=$4 min=$5 mode=$6 path=$7
    local res="$TMP/res/$label" err="$TMP/err/$label" left t out rc tries=0 fail ts size epoch age rank msg
    left=$((DEADLINE - $(date +%s)))
    if [ "$left" -lt 2 ]; then
        echo "$label|$rot|$R_UNCHECKED|-1|0|$label: UNCHECKED (out of time)" > "$res"; return
    fi
    while :; do
        t=$((left < PROBE_T ? left : PROBE_T))
        out=$(lsf "$mode" "$rot/$path" "$t" 2>"$err"); rc=$?
        tries=$((tries + 1))
        case $rc in
            0) [ -n "$out" ] && break
               echo "$label|$rot|$R_CRIT|-1|0|$label: MISSING ($rot/$path)" > "$res"; return ;;
            3|4) echo "$label|$rot|$R_CRIT|-1|0|$label: MISSING ($rot/$path)" > "$res"; return ;;
            124) fail="$label: TIMEOUT after ${t}s ($rot/$path)" ;;
            *) fail="$label: RCLONE ERROR (exit $rc): $(head -1 "$err" | tr -d '|' | cut -c1-80)" ;;
        esac
        left=$((DEADLINE - $(date +%s)))
        if [ "$tries" -ge 2 ] || [ "$left" -lt 3 ]; then
            echo "$label|$rot|$R_UNKNOWN|-1|0|$fail" > "$res"; return
        fi
    done
    if [ "$mode" = file ]; then
        out=$(head -1 <<< "$out")
    else
        out=$(sort -t'|' -k1,1r -k2,2nr <<< "$out" | head -1)
    fi
    ts=${out%%|*}; size=${out##*|}
    epoch=$(date -d "$ts" +%s 2>/dev/null) || {
        echo "$label|$rot|$R_UNKNOWN|-1|0|$label: unparseable mtime '$ts'" > "$res"; return; }
    age=$(( (START - epoch) / 86400 ))
    rank=$R_OK; msg="$label: ${age}d"
    if   [ "$age" -ge "$crit" ]; then rank=$R_CRIT; msg="$label: STALE ${age}d (crit ${crit}d)"
    elif [ "$age" -ge "$warn" ]; then rank=$R_WARN; msg="$label: aging ${age}d (warn ${warn}d)"
    fi
    if [ "$size" -lt "$min" ] 2>/dev/null; then
        rank=$R_CRIT; msg="$label: TOO SMALL ${size}B (floor ${min}B), age ${age}d"
    fi
    echo "$label|$rot|$rank|$age|$size|$msg" > "$res"
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

worst=$R_OK; problems=""; unknown=0; w_total=0; w_ok=0; w_worst=0; m1_age=-1; m2_age=-1
for f in "$TMP"/res/*; do
    IFS='|' read -r label rot rank age size msg < "$f"
    [ "$rank" -gt "$worst" ] && worst=$rank
    [ "$rank" -eq "$R_UNCHECKED" ] || [ "$rank" -eq "$R_UNKNOWN" ] && unknown=$((unknown+1))
    case "$rot" in
        Weekly-1)  w_total=$((w_total+1)); [ "$rank" -eq "$R_OK" ] && w_ok=$((w_ok+1))
                   [ "$age" -gt "$w_worst" ] && w_worst=$age ;;
        Monthly-1) [ "$age" -gt "$m1_age" ] && m1_age=$age ;;
        Monthly-2) [ "$age" -gt "$m2_age" ] && m2_age=$age ;;
    esac
    [ "$rank" -ne "$R_OK" ] && problems+="$rank|$msg"$'\n'
done
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
elapsed=$(( $(date +%s) - START ))
perf="weekly_worst_age=${w_worst}d;$W_WARN;$W_CRIT monthly1_age=${m1_age}d;$M_WARN;$M_CRIT monthly2_age=${m2_age}d;$M_WARN;$M_CRIT stale=${count} unknown=${unknown} elapsed=${elapsed}s"
echo "BACKUPS $word - ${head}Weekly-1 ${w_ok}/${w_total} fresh (worst ${w_worst}d)${unchecked}; Monthly-1 $(days "$m1_age"); Monthly-2 $(days "$m2_age") | $perf"
[ -n "$problems" ] && echo "$problems"
exit $status
