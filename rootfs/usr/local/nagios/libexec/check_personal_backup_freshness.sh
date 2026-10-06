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
# One `rclone cat` of the folder reads every marker in a single process. That
# is the budget: check_backup_freshness already takes ~10s of the agent's 15s
# command_timeout with one rclone per sentinel, so this stays a separate check.
#
# A rotation is CRITICAL when its marker is missing or unreadable, when the
# last run's rclone exit was not 0, or when it is past crit. A failed run still
# writes its marker, so it shows here on the next check, not days later.
#
# rclone and its config are ro-mounted from the host into the agent container,
# as for check_backup_freshness; runs unprivileged as the nrpe user.

RCLONE=${RCLONE:-/usr/local/bin/rclone}
CONF=${CONF:-/etc/nagios/rclone.conf}
BASE=${BASE:-pcloud:Backups/Rotations}
DIRECTORIES="Documents Downloads Autosync Projects"
NOW=$(date +%s)

[ -x "$RCLONE" ] || { echo "UNKNOWN - $RCLONE not mounted into agent container"; exit 3; }
[ -r "$CONF" ]   || { echo "UNKNOWN - $CONF not readable"; exit 3; }

W_WARN=9  W_CRIT=16    # days — Weekly-1 runs Fridays 06:00
M_WARN=70 M_CRIT=100   # days — each monthly rotation fires every other month

markers=$(timeout 12 "$RCLONE" --config "$CONF" cat "$BASE" 2>/dev/null)
rc=$?
if [ "$rc" -eq 124 ]; then
    echo "UNKNOWN - timed out reading $BASE"; exit 3
fi
if [ -z "$markers" ]; then
    echo "PERSONAL BACKUPS CRITICAL - no markers readable at $BASE (rclone exit $rc)"; exit 2
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
echo "PERSONAL BACKUPS $word - ${summary%; } | ${perf}problems=${#problems[@]}"
for p in "${problems[@]}"; do echo "$p"; done
exit $status
