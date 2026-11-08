#!/bin/bash
# check_cold_copy_freshness.sh — the cold copy's freshness (Nagios/NRPE)
#
# WHY THIS CHECK EXISTS AT ALL. Until 2026-11-08 every copy of Scott's personal
# data lived in one pCloud account: ~/pCloudDrive IS the primary store, and the
# "backup" was pCloud to pCloud (pbs's Files module, into
# pcloud:Backups/<directory>/<rotation>). Same account, same provider, same
# failure domain. 11 of 15 server databases were single-homed there too,
# mcp-memory and trentina included.
#
# The independent medium was a 512 GB micro-SD. It had been broken since at
# least 2026-11-02 — source 628 GiB against a 469 GiB card, full, contents owned
# by the wrong uid — and nobody noticed for months, because NOTHING WATCHED IT.
# It was retired on 2026-11-07 (RT#1547). The 4 TB drive that replaced it is
# only an improvement if this check exists, so this file is the point of the
# exercise, not an accessory to it.
#
# WHAT IT READS. pbs 2.6.0's ColdCopy module writes one marker per host after
# each run, one line per item, to the same folder as the Files markers:
#
#   pcloud:Backups/Rotations/ColdCopy.<fqdn>
#   ColdCopy|<item>|<fqdn>|<start epoch>|<end epoch>|<rclone exit>
#
# backup-freshness-collect.sh collects those lines with the same single
# `rclone cat` it already did for Files|, so this costs no extra pCloud read.
# Like its sibling, this plugin only reads the status file: a live pCloud listing
# inside NRPE's 15s command_timeout is what produced UNKNOWNs with nothing wrong
# (7.0.0).
#
# WHY NO ITEM LIST HERE. check_personal_backup_freshness.sh hard-codes
# DIRECTORIES and carries a warning that the list MUST track pbs.sh, because a
# name it no longer syncs leaves a marker that can never be refreshed and a
# CRITICAL nobody can clear. ColdCopy discovers its items from the account at
# runtime, so there is no list to drift: this judges whatever items the marker
# reports. The failure that replaces "stale name" is "no marker at all", which
# is CRITICAL below and is also what a drive nobody plugged in looks like.
#
# WHERE IT RUNS, AND WHY THAT MATTERS. On gloval, not on the laptop holding the
# drive. The drive is only present when Scott docks and unlocks it, so a check
# running next to it could only report when it was already running. Reading the
# marker from pCloud means a laptop that is off, or a drive nobody plugged in,
# is precisely the condition that alerts — and the check needs no change when
# the drive moves to a dedicated host, because it follows the marker's hostname.
#
# THRESHOLDS. The trigger is physical: unlocking the drive starts the sync (pbs
# systemd/breetai/, and cold-copy.sh explains why it is not a timer). So the
# cadence is however often Scott docks, and the thresholds forgive travel
# without forgiving rot: WARNING at 10 days, CRITICAL at 24. Three missed weeks
# is a trip. Four is the micro-SD happening again.

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "COLD COPY UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/personal-backup-freshness.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/backup-freshness-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
REFRESH=${REFRESH:-1200}
STALE=${STALE:-7200}
BASE=pcloud:Backups/Rotations
NOW=$(date +%s)

WARN=${WARN:-10}   # days
CRIT=${CRIT:-24}   # days

cl_open PBKUP "COLD COPY" personal   # exits UNKNOWN "collector stale" when it must
raw=$CL_RAW collected=$CL_AGE kicked=$CL_KICKED
head_line=$(grep -m1 -E '^PBKUP generated=[0-9]+ seen=[0-9]+ rc=[0-9]+' <<< "$raw")
if [ -z "$head_line" ]; then
    cl_kick personal
    echo "COLD COPY UNKNOWN - collector stale: $STATUS is truncated or unrecognised"
    exit 3
fi
seen=$(cl_field seen "$head_line")
rc=$(cl_field rc "$head_line")
lastfail=$(cl_field lastfail "$head_line")
if [ $((NOW - seen)) -ge "$STALE" ]; then
    echo "COLD COPY UNKNOWN - collector stale: pCloud last answered $(cl_hm $((NOW - seen))) ago${lastfail:+ (last attempt: $lastfail)}"
    exit 3
fi
if [ "$rc" -eq 124 ]; then
    echo "COLD COPY UNKNOWN - collector timed out reading $BASE and has no earlier markers"
    exit 3
fi
markers=$(grep -E '^PBKUP marker=ColdCopy\|' <<< "$raw" | cut -d= -f2-)
all=$(grep -E '^PBKUP marker=' <<< "$raw" | cut -d= -f2-)
# A read that failed part way would otherwise look like "no cold copy has ever run".
if [ "$rc" -ne 0 ] || [ -z "$all" ]; then
    echo "COLD COPY CRITICAL - cannot read markers at $BASE (rclone exit $rc)"; exit 2
fi

# The folder read fine and holds markers, but none of them are ours. Either the
# cold copy has never completed an item, or nobody has docked the drive since
# the markers were last pruned. Both are the thing this check is for.
if [ -z "$markers" ]; then
    echo "COLD COPY CRITICAL - no ColdCopy marker at $BASE: the cold copy has never run, or the drive has not been plugged in | items=0 collected_age=${collected}s;;${STALE}"
    exit 2
fi

status=0; problems=(); total=0; fresh=0; worst=-1; newest=-1; hosts=""
# `started` is read into _ deliberately: only the end time and the rclone exit
# are judged here. A marker's start time says when a run began, which tells you
# nothing about whether it finished.
while IFS='|' read -r _ item host _ finished rclone_exit; do
    total=$((total+1)); st=0; msg=""

    # A line with no item name is a truncated or corrupt marker. Skipping it
    # (as this did until Gatehouse caught it on #149) let a marker set of
    # nothing but malformed lines come out as "OK - 0/0 items fresh" -- a
    # monitoring check going green on no evidence, which is precisely how the
    # micro-SD stayed unnoticed for months.
    if [ -z "$item" ]; then
        st=2; msg="malformed ColdCopy marker: no item name"
        item="(unnamed)"
    else
        case "$hosts" in *" $host "*) ;; *) hosts="$hosts $host ";; esac
    fi

    if [ "$st" -ne 0 ]; then
        :
    elif ! [[ $finished =~ ^[0-9]+$ && $rclone_exit =~ ^[0-9]+$ ]]; then
        st=2; msg="$item: unreadable marker"
    else
        age=$(( (NOW - finished) / 86400 ))
        [ "$age" -gt "$worst" ] && worst=$age
        { [ "$newest" -lt 0 ] || [ "$age" -lt "$newest" ]; } && newest=$age
        if   [ "$rclone_exit" -ne 0 ]; then st=2; msg="$item: last run FAILED (rclone exit $rclone_exit), ${age}d ago"
        elif [ "$age" -ge "$CRIT" ];   then st=2; msg="$item: STALE ${age}d (crit ${CRIT}d)"
        elif [ "$age" -ge "$WARN" ];   then st=1; msg="$item: aging ${age}d (warn ${WARN}d)"
        fi
    fi

    [ "$st" -gt "$status" ] && status=$st
    if [ "$st" -eq 0 ]; then fresh=$((fresh+1)); else problems+=("$msg"); fi
done <<< "$markers"

# Belt to the malformed-line braces above: never return OK having judged nothing.
# An OK with no items behind it is a check that has stopped checking.
if [ "$total" -eq 0 ]; then
    echo "COLD COPY CRITICAL - ColdCopy markers present at $BASE but none could be parsed | items=0 collected_age=${collected}s;;${STALE}"
    exit 2
fi

case $status in 0) word=OK;; 1) word=WARNING;; *) word=CRITICAL;; esac
hosts=$(echo "$hosts" | tr -s ' ' | sed 's/^ //;s/ $//;s/ /,/g')
echo "COLD COPY $word - $fresh/$total items fresh on ${hosts:-unknown} (newest ${newest}d, worst ${worst}d)${kicked} | worst_age=${worst}d;$WARN;$CRIT newest_age=${newest}d;; items=$total problems=${#problems[@]} collected_age=${collected}s;;${STALE}"
for p in "${problems[@]}"; do echo "$p"; done
exit $status
