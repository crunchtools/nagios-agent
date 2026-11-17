#!/bin/bash
# check_skills_sync.sh — is every seat on a host running current josui-skills?
#
# A josui-skills merge used to reach no seat until it restarted, and nothing
# said so: after josui-skills#124 merged, Dolza's shared checkout sat two
# merges behind, three Exedore seats on an older commit, and one with no
# skills at all (crunchtools/developer#42). The seats now fast-forward every
# 10 minutes, and this is what notices when that stops working.
#
# Usage: check_skills_sync.sh <host>       one Nagios service per host
#
# The seats a host must report are listed in /etc/nagios/skills-sync.conf
# (deploy/nagios-agent/skills-sync.conf), "<host> <seat>...", so a seat whose
# marker never arrives is noticed rather than simply absent.
#
# Each seat's marker (written by developer-skills-sync, copied to pCloud by
# the host's skills-sync-push timer, read by skills-sync-collect.sh):
#
#   OK        state=current, fetched within FETCH_STALE (1h); or drift
#             younger than WARN ("within grace")
#   WARNING   drift older than WARN (1h); the marker is missing or older than
#             MARKER_STALE (30m), so the sync or the push is not running;
#             or the last good fetch is older than FETCH_STALE, so "current"
#             only means current as of then
#   CRITICAL  drift older than CRIT (6h)
#   UNKNOWN   the collector is stale or could not read pCloud
#
# drift is HEAD differing from origin/main: behind (a fast-forward that has
# not happened), diverged (local commits; the sync never merges, a person
# must look), or off-branch. Its age runs from drift_since, the first pass
# that saw it. The output names the worst seat first, then every problem.
# Thresholds are env overrides, in seconds.

HOST="${1:-}"
SEATS="${SEATS:-/etc/nagios/skills-sync.conf}"
if ! [[ $HOST =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "SKILLS SYNC UNKNOWN - usage: check_skills_sync.sh <host>"
    exit 3
fi
if [ ! -r "$SEATS" ]; then
    echo "SKILLS SYNC UNKNOWN - cannot read $SEATS"
    exit 3
fi
read -r -a expected <<<"$(awk -v h="$HOST" '$1 !~ /^#/ && $1 == h { $1 = ""; print; exit }' "$SEATS")"
if [ "${#expected[@]}" -eq 0 ]; then
    echo "SKILLS SYNC UNKNOWN - no seats listed for $HOST in $SEATS"
    exit 3
fi

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "SKILLS SYNC UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/skills-sync.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/skills-sync-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
REFRESH=${REFRESH:-300}
STALE=${STALE:-3600}
WARN=${WARN:-3600}
CRIT=${CRIT:-21600}
MARKER_STALE=${MARKER_STALE:-1800}
FETCH_STALE=${FETCH_STALE:-3600}
NOW=$(date +%s)

cl_open SKSYNC "SKILLS SYNC"   # exits UNKNOWN "collector stale" when it must
raw=$CL_RAW collected=$CL_AGE kicked=$CL_KICKED

head_line=$(grep -m1 -E '^SKSYNC generated=[0-9]+ seen=[0-9]+ rc=[0-9]+' <<< "$raw")
if [ -z "$head_line" ]; then
    cl_kick
    echo "SKILLS SYNC UNKNOWN - collector stale: $STATUS is truncated or unrecognised"
    exit 3
fi
seen=$(cl_field seen "$head_line")
rc=$(cl_field rc "$head_line")
if [ $((NOW - seen)) -ge "$STALE" ]; then
    echo "SKILLS SYNC UNKNOWN - collector stale: pCloud last answered $(cl_hm $((NOW - seen))) ago"
    exit 3
fi
mine=$(grep -E "^SKSYNC marker=SKILLSSYNC host=$HOST seat=" <<< "$raw" | cut -d= -f2-)
if [ "$rc" -ne 0 ] && [ -z "$mine" ]; then
    echo "SKILLS SYNC UNKNOWN - cannot read markers at pcloud:Monitoring/SkillsSync (rclone exit $rc)"
    exit 3
fi

dur() { if [ "$1" -ge 3600 ]; then echo "$(( $1 / 3600 ))h$(( $1 % 3600 / 60 ))m"; else echo "$(( $1 / 60 ))m"; fi; }
status=0 current=0 worst_st=-1 worst_msg="" max_drift=0
problems=()
for seat in "${expected[@]}"; do
    line=$(grep -m1 -E "^SKILLSSYNC host=$HOST seat=$seat " <<< "$mine")
    st=0 msg=""
    if [ -z "$line" ]; then
        st=1; msg="$seat: no marker: its sync or push has never run"
    else
        written=$(cl_field written "$line"); state=$(cl_field state "$line")
        since=$(cl_field drift_since "$line"); fetched=$(cl_field fetched "$line")
        head=$(cl_field head "$line"); origin=$(cl_field origin "$line")
        if ! [[ $written =~ ^[0-9]+$ && $since =~ ^[0-9]+$ && $fetched =~ ^[0-9]+$ && -n $state ]]; then
            st=1; msg="$seat: unreadable marker"
        elif [ $((NOW - written)) -ge "$MARKER_STALE" ]; then
            st=1; msg="$seat: last report $(dur $((NOW - written))) ago: the sync or the push is not running"
        elif [ "$state" = current ]; then
            if [ $((NOW - fetched)) -ge "$FETCH_STALE" ]; then
                st=1; msg="$seat: no successful fetch for $(dur $((NOW - fetched))): current only as of then"
            fi
        else
            drift=$((NOW - since))
            [ "$drift" -gt "$max_drift" ] && max_drift=$drift
            what="$seat: $state for $(dur "$drift") (HEAD ${head:0:7}, origin/main ${origin:0:7})"
            if   [ "$drift" -ge "$CRIT" ]; then st=2; msg="$what"
            elif [ "$drift" -ge "$WARN" ]; then st=1; msg="$what"
            fi
        fi
    fi
    if [ "$st" -eq 0 ]; then
        [ "${state:-}" = current ] && current=$((current + 1))
    else
        problems+=("$msg")
    fi
    if [ "$st" -gt "$worst_st" ]; then worst_st=$st; worst_msg=$msg; fi
    [ "$st" -gt "$status" ] && status=$st
    state=
done

case $status in 0) word=OK;; 1) word=WARNING;; *) word=CRITICAL;; esac
total=${#expected[@]}
summary="$HOST: $current/$total seats current"
[ "$status" -ne 0 ] && summary="$summary; worst $worst_msg"
echo "SKILLS SYNC $word - $summary${kicked} | drift_max=${max_drift}s;$WARN;$CRIT;0 seats=$total problems=${#problems[@]} collected_age=${collected}s;;${STALE}"
for p in "${problems[@]}"; do echo "$p"; done
exit $status
