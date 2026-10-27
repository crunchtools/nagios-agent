#!/bin/bash
# backup-freshness-collect.sh — read pCloud backup facts off the NRPE hot path (7.0.0)
#
# THE PROBLEM. check_backup_freshness.sh and check_personal_backup_freshness.sh
# used to list pCloud live, inside NRPE's 15s command_timeout. pCloud listings
# are usually 1-3s and sometimes 20s, so the servers check ran 19 listings
# under a 12s deadline with 6s each and still produced 11 UNKNOWNs in 48h
# ("monthly1-crunchtools: TIMEOUT after 5s"), and the personal check timed out
# reading pcloud:Backups/Rotations the same way. Nothing was wrong with any
# backup. The budget was wrong for the medium.
#
# THE SPLIT. This script does the slow reads with a generous budget (BUDGET,
# 120s; PROBE_T, 30s a listing) and writes what it saw to a status file. The
# plugins only read that file, so they answer in milliseconds.
#
# WHO RUNS THIS, AND WHEN. The plugins start it, through
# `podman_exec.sh --detach` into nagios-agent.crunchtools.com, whenever the
# status file is older than their REFRESH (20m) or missing, and then judge the
# file the previous run wrote. So the Nagios check_interval is the clock, as
# constitution XVI requires, and there is no timer to forget about. A run that
# is already going holds a flock and any second start exits at once. The exec
# runs as root, but rclone needs nothing root has: root is only the default
# exec user, and the state dir is root-owned.
#
# WHAT IT WRITES. One status file per mode in STATE_DIR, replaced atomically
# (written to a temp file in the same directory, then renamed), so a reader
# sees the old file or the new one, never half of either:
#
#   servers   backup-freshness.status
#     BKUP generated=<epoch> elapsed=<s>
#     BKUP item=<label> rot=<rotation> seen=<epoch> result=ok epoch=<mtime> size=<bytes> floor=<bytes>
#     BKUP item=<label> rot=<rotation> seen=<epoch> result=missing floor=<bytes> path=<rot/path>
#     BKUP item=<label> rot=<rotation> seen=<epoch> result=timeout|error|unchecked|badtime floor=<bytes> msg=<text>
#     BKUP end=1
#   personal  personal-backup-freshness.status
#     PBKUP generated=<epoch> seen=<epoch> rc=<rclone exit> [lastfail=<why>]
#     PBKUP marker=Files|<directory>|<rotation>|<start>|<end>|<rclone exit>
#     PBKUP end=1
#
# seen is when pCloud last actually answered for that item. A listing that
# times out or errors keeps the previous run's answer for that item, seen and
# all, instead of overwriting a good observation with "could not look": an
# mtime read an hour ago is still the mtime. The plugin turns an item whose
# seen is older than its STALE (2h) into UNKNOWN, so a pCloud outage still
# shows, just not on the first slow listing.
#
# Facts only: labels, mtimes, sizes, rclone exit codes. All thresholds live in
# the plugins, except the per-dump size floor, which is a property of the dump
# and travels with it, as in srv-nightly-dump-collect.sh.

set -uo pipefail

MODE=${1:-}
RCLONE=${RCLONE:-/usr/local/bin/rclone}
CONF=${CONF:-/etc/nagios/rclone.conf}
STATE_DIR=${STATE_DIR:-/var/lib/nagios-agent}
BUDGET=${BUDGET:-120}     # seconds for the whole servers run
PROBE_T=${PROBE_T:-30}    # seconds per listing
PERSONAL_T=${PERSONAL_T:-60}
BASE=${BASE:-pcloud:Backups/Servers/lotor.dc3.crunchtools.com}
ROTATIONS=${ROTATIONS:-pcloud:Backups/Rotations}

case "$MODE" in
    servers)  STATUS="$STATE_DIR/backup-freshness.status" ;;
    personal) STATUS="$STATE_DIR/personal-backup-freshness.status" ;;
    *) echo "usage: backup-freshness-collect.sh servers|personal" >&2; exit 3 ;;
esac

mkdir -p "$STATE_DIR" || exit 3
exec 9>"$STATE_DIR/.$MODE.lock" || exit 3
flock -n 9 || exit 0   # a run is already in progress; it will write the file

[ -x "$RCLONE" ] || { echo "$RCLONE not mounted into agent container" >&2; exit 3; }
[ -r "$CONF" ]   || { echo "$CONF not readable" >&2; exit 3; }

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

publish() { # <file>: atomic replace, world-readable for the nrpe user
    local out="$STATUS.tmp.$$"
    cp "$1" "$out"         || { echo "publish: cannot write $out" >&2; rm -f "$out"; return 1; }
    chmod 0644 "$out"      || { echo "publish: cannot chmod $out" >&2; rm -f "$out"; return 1; }
    mv -f "$out" "$STATUS" || { echo "publish: cannot rename $out to $STATUS" >&2; rm -f "$out"; return 1; }
}

previous() { # <grep -E pattern>: matching lines of the current status file, if any
    [ -r "$STATUS" ] && grep -E "$1" "$STATUS"
}

collect_personal() {
    local markers rc tries=0 lastfail=""
    while :; do
        markers=$(timeout "$PERSONAL_T" "$RCLONE" --config "$CONF" cat "$ROTATIONS" 2>/dev/null)
        rc=$?
        tries=$((tries + 1))
        [ "$rc" -eq 0 ] && [ -n "$markers" ] && break
        [ "$tries" -ge 2 ] && break
    done
    {
        if [ "$rc" -eq 124 ] && [ -n "$(previous '^PBKUP marker=')" ]; then
            # Timed out twice: keep the last markers pCloud gave us, and their seen.
            lastfail="timeout"
            prev_seen=$(previous '^PBKUP generated=' | grep -oE 'seen=[0-9]+' | cut -d= -f2)
            prev_rc=$(previous '^PBKUP generated=' | grep -oE ' rc=[0-9]+' | cut -d= -f2)
            echo "PBKUP generated=$START seen=${prev_seen:-0} rc=${prev_rc:-124} lastfail=$lastfail"
            previous '^PBKUP marker='
        else
            echo "PBKUP generated=$START seen=$START rc=$rc"
            printf '%s\n' "$markers" | tr -cd '\012\040-\176' | grep '^Files|' | sed 's/^/PBKUP marker=/'
        fi
        echo "PBKUP end=1"
    } > "$TMP/status"
    publish "$TMP/status"
}

# label|rotation|min_bytes|mode|path
#   mode=file : path is the exact dump file
#   mode=dir  : newest *.db / *.sqlite* under path (recursive); ties go to the largest
# Weekly-1 holds one dump (or data dir) per service. Monthly-1/2 alternate
# months and are proxied by two representative dumps each. The .sql dumps never
# exist on lotor's disk: pbs writes them inside its container and copies them
# straight to pCloud. Decommissioned services (zabbix) are deliberately absent.
# takeda (ex-openclaw, renamed 2026-10-25) is takeda-db.
SENTINELS="
crunchtools-db|Weekly-1|15000000|file|crunchtools.com/backups/all-databases.sql
educatedconfusion-db|Weekly-1|10000000|file|educatedconfusion.com/backups/all-databases.sql
learn-wiki-db|Weekly-1|100000000|file|learn.fatherlinux.com/data/backups/my_wiki.sql
rt-db|Weekly-1|15000000|file|rt.fatherlinux.com/data/backups/rt4.sql
rootsofthevalley-db|Weekly-1|200000000|file|rootsofthevalley.org/backups/all-databases.sql
images-rotv-db|Weekly-1|400000|file|images.rootsofthevalley.org/backups/all-databases.sql
postiz-db|Weekly-1|1000000|file|postiz.crunchtools.com/backups/all-databases.sql
acquacotta-db|Weekly-1|1000|dir|acquacotta.crunchtools.com/data
kagetora-db|Weekly-1|100000|dir|kagetora.crunchtools.com/data
takeda-db|Weekly-1|50000|dir|takeda.crunchtools.com/data
mcp-feeds-db|Weekly-1|30000000|file|mcp-feeds.crunchtools.com/data/feeds.db
mcp-memory-db|Weekly-1|5000000|dir|mcp-memory.crunchtools.com/data
mcp-metsuke-db|Weekly-1|50000|file|mcp-metsuke.crunchtools.com/data/metsuke.db
trentina-db|Weekly-1|200000|dir|trentina.crunchtools.com/data
newsletter-db|Weekly-1|1000000|file|newsletter.crunchtools.com/data/kill-the-newsletter.db
monthly1-crunchtools|Monthly-1|15000000|file|crunchtools.com/backups/all-databases.sql
monthly1-rotv|Monthly-1|200000000|file|rootsofthevalley.org/backups/all-databases.sql
monthly2-crunchtools|Monthly-2|15000000|file|crunchtools.com/backups/all-databases.sql
monthly2-rotv|Monthly-2|200000000|file|rootsofthevalley.org/backups/all-databases.sql
"

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

probe() { # writes one BKUP item line to $TMP/res/<label>
    local label=$1 rot=$2 min=$3 mode=$4 path=$5
    local res="$TMP/res/$label" err="$TMP/err/$label" head="BKUP item=$label rot=$rot"
    local deadline=$((START + BUDGET)) left t out rc tries=0 fail ts size epoch
    left=$((deadline - $(date +%s)))
    if [ "$left" -lt 2 ]; then
        echo "$head seen=$(date +%s) result=unchecked floor=$min msg=$label: UNCHECKED (out of time)" > "$res"; return
    fi
    while :; do
        t=$((left < PROBE_T ? left : PROBE_T))
        out=$(lsf "$mode" "$rot/$path" "$t" 2>"$err"); rc=$?
        tries=$((tries + 1))
        case $rc in
            0) [ -n "$out" ] && break
               echo "$head seen=$(date +%s) result=missing floor=$min path=$rot/$path" > "$res"; return ;;
            3|4) echo "$head seen=$(date +%s) result=missing floor=$min path=$rot/$path" > "$res"; return ;;
            124) fail="timeout floor=$min msg=$label: TIMEOUT after ${t}s ($rot/$path)" ;;
            *) fail="error floor=$min msg=$label: RCLONE ERROR (exit $rc): $(head -1 "$err" | tr -cd '\040-\176' | tr -d '|' | cut -c1-80)" ;;
        esac
        left=$((deadline - $(date +%s)))
        if [ "$tries" -ge 2 ] || [ "$left" -lt 3 ]; then
            echo "$head seen=$(date +%s) result=$fail" > "$res"; return
        fi
    done
    if [ "$mode" = file ]; then
        out=$(head -1 <<< "$out")
    else
        out=$(sort -t'|' -k1,1r -k2,2nr <<< "$out" | head -1)
    fi
    ts=${out%%|*}; size=${out##*|}
    if ! epoch=$(date -d "$ts" +%s 2>/dev/null) || ! [[ $size =~ ^[0-9]+$ ]]; then
        echo "$head seen=$(date +%s) result=badtime floor=$min msg=$label: unparseable listing '$(tr -cd '\040-\176' <<< "$out" | cut -c1-60)'" > "$res"; return
    fi
    echo "$head seen=$(date +%s) result=ok epoch=$epoch size=$size floor=$min" > "$res"
}

collect_servers() {
    local n=0 label rot min mode path line prev
    mkdir "$TMP/res" "$TMP/err"
    # Waves of 7: each rclone process costs ~40-70MB and the agent container is
    # memory-capped at 1g, so unbounded parallelism gets the probes OOM-killed.
    while IFS='|' read -r label rot min mode path; do
        [ -z "$label" ] && continue
        probe "$label" "$rot" "$min" "$mode" "$path" &
        n=$((n+1)); [ $((n % 7)) -eq 0 ] && wait
    done <<< "$SENTINELS"
    wait
    {
        echo "BKUP generated=$START elapsed=$(( $(date +%s) - START ))"
        while IFS='|' read -r label rot min mode path; do
            [ -z "$label" ] && continue
            line=$(cat "$TMP/res/$label" 2>/dev/null)
            [ -n "$line" ] || line="BKUP item=$label rot=$rot seen=$START result=error floor=$min msg=$label: probe wrote nothing"
            case "$line" in
                *" result=timeout "*|*" result=error "*|*" result=unchecked "*)
                    # Could not look this time: keep the last real answer if there is one.
                    prev=$(previous "^BKUP item=$label rot=$rot seen=[0-9]+ result=(ok|missing) " | head -1)
                    [ -n "$prev" ] && line=$prev ;;
            esac
            echo "$line"
        done <<< "$SENTINELS"
        echo "BKUP end=1"
    } > "$TMP/status"
    publish "$TMP/status"
}

"collect_$MODE"
