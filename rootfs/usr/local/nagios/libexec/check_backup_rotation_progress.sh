#!/bin/bash
#############################################################################
# check_backup_rotation_progress.sh — a pbs rotation wedged in flight (9.7.0)
#
# Usage: check_backup_rotation_progress.sh
#
# WHY THIS EXISTS
#
# RT #1594 made every pbs backup rotation hold a systemd block shutdown
# inhibitor for the life of its run, so an OS update cannot reboot the host
# mid-backup: the update is refused and retried every 30 minutes until the
# rotation finishes. Verified live — a rotation held an OS update off for over
# three hours.
#
# That turned "a rotation that never finishes" from a late backup into a host
# that never takes an OS update again, silently, and nothing watched for it.
# Backup Freshness and Personal Backup Freshness judge the MARKERS a rotation
# writes when it COMPLETES, so a run wedged at hour three is byte-identical to a
# run that never started, and their thresholds are 16 and 100 days: a wedge
# surfaces a fortnight late, as staleness, and never as "something is stuck
# right now". This check is the "right now" half.
#
# It does NOT bound a run's lifetime and must not grow into that. Killing a
# backup that might be slow rather than stuck is the behaviour RT #1594 was
# filed to stop. Visibility is the whole job.
#
# WHAT COUNTS AS STUCK
#
# Elapsed time cannot answer it. ServerBackups-Weekly-1 takes roughly ten hours
# normally and PersonalBackups-Weekly-1 takes sixteen minutes, so any single
# clock that tolerates the first is blind to the second, and one tight enough
# for the second pages every Saturday.
#
# Nor can rclone's byte counter on its own. On 2026-11-09 a personal rotation
# whose mirror was 39 days stale sat at
#   22.978 GiB / 22.978 GiB, 100%, 0 B/s, ETA -
# byte-identical for two and a half hours, 4h20m into the run, deep in a
# `--delete-during` pass against pCloud. `--stats-one-line` does not count
# deletions, so a long legitimate delete pass and a wedge look identical in the
# log. That run was ruled SLOW, not wedged, and a check that pages through it
# is a check that gets acknowledged every time it fires.
#
# What separated them was CPU: that rotation was still burning about half a
# CPU-second a minute, continuously, with steady memory. A wedged rclone burns
# none. Host networking leaves no per-container network counters to lean on, so
# CPU time and the journal's own stats lines are what there is.
#
# So the verdict is on BOTH, and a rotation is stuck only when NEITHER moves:
#
#   frozen = time since the rclone stats payload last changed
#            AND since the container's CPU time last increased
#
# Either one moving is progress, and progress is quiet. A slow run moves CPU; a
# transferring run moves bytes; a wedge moves neither.
#
# CPU time is cumulative, so proving it stopped needs two samples. That is what
# rotation-progress-collect.sh is for — see its header for why a five-minute
# baseline beats a sleep inside this check. This plugin only judges the file it
# writes, and starts it detached when the file is due, so the Nagios
# check_interval is the sampling clock (constitution XVI).
#
# VERDICTS
#
#   OK       nothing in flight; or in flight and something is still moving; or
#            frozen for less than its window; or no baseline yet.
#   WARNING  frozen for its window. Also a run past its HARD ceiling that is
#            still moving — pathological, but it will finish.
#   CRITICAL frozen AND past HARD. Two independent conditions, so it is hard to
#            reach by accident: the run cannot finish and OS updates have been
#            blocked for half a day or more. A stuck backup is not an
#            emergency; at that point it is not nothing either.
#   UNKNOWN  collector stale, or a rotation whose sample could not be taken. A
#            monitoring failure is never reported as a healthy backup.
#
# Windows are per family because personal and server rotations differ by an
# order of magnitude. Families come from the container name, so a rotation added
# later is covered without editing this plugin.
#############################################################################

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "BACKUP ROTATIONS UNKNOWN - cannot load collector-lib.sh"; exit 3; }

STATUS=${STATUS:-$STATE_DIR/rotation-progress.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/rotation-progress-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-240}    # seconds: start a sample run when the file is this old
STALE=${STALE:-1800}       # seconds: older than this and the samples are not trusted

# Frozen windows and lifetime ceilings, seconds. A change here is a MAJOR bump:
# the server's service definition is a consumer of this interface.
PERSONAL_STALL=${PERSONAL_STALL:-2700}    # 45m  — a normal personal run is ~16m
PERSONAL_HARD=${PERSONAL_HARD:-43200}     # 12h  — the live slow outlier was 4h20m
SERVER_STALL=${SERVER_STALL:-7200}        # 2h
SERVER_HARD=${SERVER_HARD:-86400}         # 24h  — a normal server run is ~10h

NOW=$(date +%s)

cl_open ROTP "BACKUP ROTATIONS"   # exits UNKNOWN "collector stale" when it must
raw=$CL_RAW collected=$CL_AGE kicked=$CL_KICKED

# Ranks sort by severity rather than by Nagios code, so an UNKNOWN on one
# rotation cannot outrank a CRITICAL finding on another:
# 0 OK, 1 WARNING, 2 UNKNOWN, 3 CRITICAL.
R_OK=0 R_WARN=1 R_UNKNOWN=2 R_CRIT=3

hm() { printf '%dh%02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )); }

worst=$R_OK
findings=""
items=0
n_stalled=0
max_elapsed=0
max_frozen=0

while IFS= read -r line; do
    name=$(cl_field item "$line")
    [ -n "$name" ] || continue
    items=$((items + 1))

    case "$name" in
        *personal*) stall=$PERSONAL_STALL hard=$PERSONAL_HARD family=personal ;;
        *server*)   stall=$SERVER_STALL   hard=$SERVER_HARD   family=server ;;
        # An unrecognised rotation gets the generous windows and says which it
        # got, rather than being judged by thresholds nobody chose for it.
        *)          stall=$SERVER_STALL   hard=$SERVER_HARD   family=unclassified ;;
    esac

    result=$(cl_field result "$line")
    started=$(cl_field started "$line")
    elapsed=$(( NOW - ${started:-0} ))
    [ "$elapsed" -lt 0 ] && elapsed=0
    [[ $started =~ ^[1-9][0-9]*$ ]] || elapsed=0
    [ "$elapsed" -gt "$max_elapsed" ] && max_elapsed=$elapsed

    if [ "$result" != ok ]; then
        msg=$(cl_field msg "$line"); msg=${msg//_/ }
        findings+="$R_UNKNOWN|$name: sample failed (${msg:-no reason recorded})"$'\n'
        [ "$R_UNKNOWN" -gt "$worst" ] && worst=$R_UNKNOWN
        continue
    fi

    cpu=$(cl_field cpu "$line")
    cpu_moved=$(cl_field cpu_moved "$line")
    flat_ts=$(cl_field flat_ts "$line")
    flat_floor=$(cl_field flat_floor "$line")
    lines=$(cl_field lines "$line")
    pay=$(cl_field pay "$line"); pay=${pay//_/ }

    # Every number below is fed to arithmetic, where bash reads a non-numeric
    # value as 0. A missing cpu_moved would make `NOW - cpu_moved` the whole
    # epoch and the rotation "frozen" since 1970 — a confident CRITICAL built
    # on a field that was not there. A sample we cannot read is UNKNOWN.
    if ! [[ $started =~ ^[0-9]+$ && $cpu_moved =~ ^[0-9]+$ && $flat_ts =~ ^[0-9]+$ && $lines =~ ^[0-9]+$ ]]; then
        findings+="$R_UNKNOWN|$name: unparseable sample line in $STATUS"$'\n'
        [ "$R_UNKNOWN" -gt "$worst" ] && worst=$R_UNKNOWN
        continue
    fi

    cpu_frozen=$(( NOW - cpu_moved ))
    [ "$cpu_frozen" -lt 0 ] && cpu_frozen=0

    # Time since the log last showed a change. With no stats line at all, rclone
    # has never reported progress, so the whole run counts as unchanged.
    if [ "${lines:-0}" -gt 0 ] && [ "${flat_ts:-0}" -gt 0 ]; then
        log_frozen=$(( NOW - flat_ts ))
        [ "$log_frozen" -lt 0 ] && log_frozen=0
        bytes_moved="$(hm "$log_frozen") ago"
    else
        # rclone has never reported progress for this run, so the whole run
        # counts as unchanged on the byte side.
        log_frozen=$elapsed
        pay="(none yet)"
        bytes_moved="never"
    fi

    # Both have to be still for the rotation to be still. The binding one is
    # whichever moved most recently.
    frozen=$log_frozen
    [ "$cpu_frozen" -lt "$frozen" ] && frozen=$cpu_frozen
    [ "$frozen" -gt "$max_frozen" ] && max_frozen=$frozen

    floor=""
    [ "${flat_floor:-0}" -eq 1 ] && [ "$frozen" -eq "$log_frozen" ] && floor="at least "

    if [ "$frozen" -ge "$stall" ]; then
        n_stalled=$((n_stalled + 1))
        detail="nothing has moved for ${floor}$(hm "$frozen") (no bytes, no CPU; ${cpu:-?} CPU-seconds used)"
        if [ "$elapsed" -ge "$hard" ]; then
            findings+="$R_CRIT|$name: running $(hm "$elapsed"), past the $(hm "$hard") ceiling, $detail; last stats: $pay"$'\n'
            [ "$R_CRIT" -gt "$worst" ] && worst=$R_CRIT
        else
            findings+="$R_WARN|$name: running $(hm "$elapsed"), $detail; last stats: $pay"$'\n'
            [ "$R_WARN" -gt "$worst" ] && worst=$R_WARN
        fi
        continue
    fi

    # Moving. Past the ceiling it is still pathological — OS updates have been
    # refused that whole time — but it is moving and will finish, so it warns.
    moving="moved $(hm "$cpu_frozen") ago (CPU), $bytes_moved (bytes)"
    if [ "$elapsed" -ge "$hard" ]; then
        findings+="$R_WARN|$name: running $(hm "$elapsed"), past the $(hm "$hard") ceiling but still moving — $moving; last stats: $pay"$'\n'
        [ "$R_WARN" -gt "$worst" ] && worst=$R_WARN
        continue
    fi
    findings+="$R_OK|$name: running $(hm "$elapsed") ($family), $moving; last stats: $pay"$'\n'
done < <(grep -E '^ROTP item=' <<< "$raw")

perf_tail="collected_age=${collected}s;;${STALE}"

if [ "$items" -eq 0 ]; then
    echo "BACKUP ROTATIONS OK - no rotation in flight${kicked} | inflight=0 stalled=0 elapsed=0s frozen=0s $perf_tail"
    exit 0
fi

findings=${findings%$'\n'}
# Worst first: the first line is all a notification carries.
ordered=$(sort -s -t'|' -k1,1nr <<< "$findings" | cut -d'|' -f2-)
head_line=$(head -1 <<< "$ordered")
count=$(wc -l <<< "$ordered")

case $worst in
    "$R_OK")   word=OK;       status=0 ;;
    "$R_WARN") word=WARNING;  status=1 ;;
    "$R_CRIT") word=CRITICAL; status=2 ;;
    *)         word=UNKNOWN;  status=3 ;;
esac

more=""
[ "$count" -gt 1 ] && more=" [+$((count - 1)) more]"
perf="inflight=$items stalled=$n_stalled elapsed=${max_elapsed}s frozen=${max_frozen}s $perf_tail"
echo "BACKUP ROTATIONS $word - ${head_line}${more}${kicked} | $perf"
[ "$count" -gt 1 ] && tail -n +2 <<< "$ordered"
exit $status
