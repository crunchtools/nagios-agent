#!/bin/bash
# check_personal_backup_freshness.sh — personal pCloud rotation freshness (Nagios/NRPE)
#
# The PersonalBackups units run pbs's Files module: a pCloud-to-pCloud sync of
# Documents, Downloads, Autosync and Projects into Weekly-1, Monthly-1 and
# Monthly-2. That sync leaves nothing behind to judge it by: copied files keep
# their source mtime and pCloud folder mtimes only move when a direct child
# changes. So pbs writes one marker per directory and rotation after each sync:
#
#   pcloud:Backups/Rotations/Files.<directory>.<rotation>
#   Files|<directory>|<rotation>|<start epoch>|<end epoch>|<rclone exit>
#
# backup-freshness-collect.sh reads every marker with one `rclone cat` and
# writes them to a status file (7.0.0). This plugin only reads that file: the
# live read inside NRPE's 15s command_timeout kept failing with "timed out
# reading pcloud:Backups/Rotations" while the backups were fine. When the file
# is missing or older than REFRESH (20m) the plugin starts the collector
# detached through `podman_exec.sh --detach` and judges the previous run's
# file, so the Nagios check_interval is the clock.
#
# A rotation is CRITICAL when its marker is missing or unreadable, when the
# last run's rclone exit was not 0, or when it is past crit. A failed run still
# writes its marker, so it shows here on the next collection, not days later.
# CRITICAL too when the collector could not read the folder at all (any rclone
# failure other than a timeout, after one retry), as before the split.
#
# UNKNOWN only for "collector stale": no status file, or one older than STALE
# (2h), or markers pCloud last answered with more than STALE ago (the
# collector keeps the previous markers through a timeout).

STATE_DIR=${STATE_DIR:-/var/lib/nagios-agent}
STATUS=${STATUS:-$STATE_DIR/personal-backup-freshness.status}
EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/backup-freshness-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
REFRESH=${REFRESH:-1200}
STALE=${STALE:-7200}
BASE=pcloud:Backups/Rotations
DIRECTORIES="Documents Downloads Autosync Projects"
NOW=$(date +%s)

W_WARN=9  W_CRIT=16    # days — Weekly-1 runs Fridays 06:00
M_WARN=70 M_CRIT=100   # days — each monthly rotation fires every other month

kick() { "$EXEC" --detach "$CONTAINER" "$COLLECT" personal >/dev/null 2>&1; }
hm() { echo "$(( $1 / 3600 ))h$(( $1 % 3600 / 60 ))m"; }

if [ ! -r "$STATUS" ]; then
    kick && started="collector started" || started="collector could not be started"
    echo "PERSONAL BACKUPS UNKNOWN - collector stale: no status file at $STATUS ($started)"
    exit 3
fi
raw=$(cat "$STATUS")
head_line=$(grep -m1 -E '^PBKUP generated=[0-9]+ seen=[0-9]+ rc=[0-9]+' <<< "$raw")
if [ -z "$head_line" ] || ! grep -qx 'PBKUP end=1' <<< "$raw"; then
    kick
    echo "PERSONAL BACKUPS UNKNOWN - collector stale: $STATUS is truncated or unrecognised"
    exit 3
fi
generated=$(grep -oE 'generated=[0-9]+' <<< "$head_line" | cut -d= -f2)
seen=$(grep -oE 'seen=[0-9]+' <<< "$head_line" | cut -d= -f2)
rc=$(grep -oE ' rc=[0-9]+' <<< "$head_line" | cut -d= -f2)
lastfail=$(grep -oE 'lastfail=[a-z]+' <<< "$head_line" | cut -d= -f2)
collected=$((NOW - generated))
kicked=""
if [ "$collected" -ge "$REFRESH" ]; then kick || kicked=" (collector could not be started)"; fi
if [ "$collected" -ge "$STALE" ]; then
    echo "PERSONAL BACKUPS UNKNOWN - collector stale: last collection $(hm "$collected") ago${kicked}"
    exit 3
fi
if [ $((NOW - seen)) -ge "$STALE" ]; then
    echo "PERSONAL BACKUPS UNKNOWN - collector stale: pCloud last answered $(hm $((NOW - seen))) ago${lastfail:+ (last attempt: $lastfail)}"
    exit 3
fi
if [ "$rc" -eq 124 ]; then
    # Only on a first run: once a read has succeeded, a timeout keeps the old markers.
    echo "PERSONAL BACKUPS UNKNOWN - collector timed out reading $BASE and has no earlier markers"
    exit 3
fi
markers=$(grep -E '^PBKUP marker=' <<< "$raw" | cut -d= -f2-)
# A read that failed part way would otherwise show its unread markers as MISSING.
if [ "$rc" -ne 0 ] || [ -z "$markers" ]; then
    echo "PERSONAL BACKUPS CRITICAL - cannot read markers at $BASE (rclone exit $rc)"; exit 2
fi

status=0; problems=(); summary=""; perf=""
for rot in Weekly-1 Monthly-1 Monthly-2; do
    if [ "$rot" = Weekly-1 ]; then warn=$W_WARN crit=$W_CRIT; else warn=$M_WARN crit=$M_CRIT; fi
    total=0; fresh=0; worst=-1
    for dir in $DIRECTORIES; do
        total=$((total+1)); st=0; msg=""
        line=$(grep -m1 "^Files|$dir|$rot|" <<< "$markers")
        IFS='|' read -r _ _ _ _ finished rclone_exit <<< "$line"
        if [ -z "$line" ]; then
            st=2; msg="$dir/$rot: MISSING marker"
        elif ! [[ $finished =~ ^[0-9]+$ && $rclone_exit =~ ^[0-9]+$ ]]; then
            st=2; msg="$dir/$rot: unreadable marker"
        else
            age=$(( (NOW - finished) / 86400 ))
            [ "$age" -gt "$worst" ] && worst=$age
            if   [ "$rclone_exit" -ne 0 ]; then st=2; msg="$dir/$rot: last run FAILED (rclone exit $rclone_exit), ${age}d ago"
            elif [ "$age" -ge "$crit" ];   then st=2; msg="$dir/$rot: STALE ${age}d (crit ${crit}d)"
            elif [ "$age" -ge "$warn" ];   then st=1; msg="$dir/$rot: aging ${age}d (warn ${warn}d)"
            fi
        fi
        [ "$st" -gt "$status" ] && status=$st
        if [ "$st" -eq 0 ]; then fresh=$((fresh+1)); else problems+=("$msg"); fi
    done
    summary+="$rot $fresh/$total fresh (worst ${worst}d); "
    label=${rot,,}
    perf+="${label//-/}_worst_age=${worst}d;$warn;$crit "
done

case $status in 0) word=OK;; 1) word=WARNING;; *) word=CRITICAL;; esac
echo "PERSONAL BACKUPS $word - ${summary%; }${kicked} | ${perf}problems=${#problems[@]} collected_age=${collected}s;;${STALE}"
for p in "${problems[@]}"; do echo "$p"; done
exit $status
