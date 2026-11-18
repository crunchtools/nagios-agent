#!/bin/bash
# check_openbao_remote.sh — an agentless host's OpenBao: unsealed, and backed up?
#
# Exedore runs its own OpenBao (a256) for the Max seats' secrets, and no NRPE
# agent, so check_openbao (which curls gloval's loopback) cannot see it. A timer
# there, openbao-health-push (crunchtools/openbao deploy/exedore/), copies its
# /v1/sys/health verdict and its newest raft snapshot's time to
# pcloud:Monitoring/OpenBao/<host>; openbao-remote-collect.sh reads them here.
#
# Usage: check_openbao_remote.sh <host>       one Nagios service per host
#
#   OK        http=200, initialized=true, sealed=false, a snapshot under SNAP_WARN
#             (26h) old, and a marker under MARKER_WARN (45m) old
#   WARNING   standby (429/472/473), as check_openbao treats it; the newest
#             snapshot older than 26h (one missed night); the marker older
#             than 45m, so the push timer or the host has stopped reporting
#   CRITICAL  sealed, not initialised, or no answer at all; no snapshot ever,
#             or the newest older than SNAP_CRIT (50h, two missed nights); no
#             marker, or one older than MARKER_CRIT (6h)
#   UNKNOWN   the collector is stale or could not read pCloud
#
# A missing or 6h-old marker is CRITICAL, not WARNING as in Skills Sync: this is
# the only view anyone has of that store, and a dead view of a secret store
# should not sit yellow while the store itself is sealed.
#
# No credential crosses here or there: sys/health is unauthenticated.
# Thresholds are env overrides, in seconds.

HOST="${1:-}"
if ! [[ $HOST =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "OPENBAO REMOTE UNKNOWN - usage: check_openbao_remote.sh <host>"
    exit 3
fi

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "OPENBAO REMOTE UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/openbao-remote.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/openbao-remote-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
REFRESH=${REFRESH:-300}
STALE=${STALE:-3600}
# A healthy marker can be ~20m old when read: a 10m push timer plus the
# collector's own refresh. 45m leaves room, as in check_skills_sync.
MARKER_WARN=${MARKER_WARN:-2700}
MARKER_CRIT=${MARKER_CRIT:-21600}
SNAP_WARN=${SNAP_WARN:-93600}
SNAP_CRIT=${SNAP_CRIT:-180000}
NOW=$(date +%s)

cl_open OBHEALTH "OPENBAO REMOTE"   # exits UNKNOWN "collector stale" when it must
raw=$CL_RAW collected=$CL_AGE kicked=$CL_KICKED

head_line=$(grep -m1 -E '^OBHEALTH generated=[0-9]+ seen=[0-9]+ rc=[0-9]+' <<< "$raw")
if [ -z "$head_line" ]; then
    cl_kick
    echo "OPENBAO REMOTE UNKNOWN - collector stale: $STATUS is truncated or unrecognised"
    exit 3
fi
seen=$(cl_field seen "$head_line")
rc=$(cl_field rc "$head_line")
if [ $((NOW - seen)) -ge "$STALE" ]; then
    echo "OPENBAO REMOTE UNKNOWN - collector stale: pCloud last answered $(cl_hm $((NOW - seen))) ago"
    exit 3
fi
line=$(grep -m1 -E "^OBHEALTH marker=OPENBAOHEALTH host=$HOST " <<< "$raw" | cut -d= -f2-)
if [ "$rc" -ne 0 ] && [ -z "$line" ]; then
    echo "OPENBAO REMOTE UNKNOWN - cannot read markers at pcloud:Monitoring/OpenBao (rclone exit $rc)"
    exit 3
fi
perf="collected_age=${collected}s;;${STALE}"
if [ -z "$line" ]; then
    echo "OPENBAO REMOTE CRITICAL - $HOST: no marker: openbao-health-push has never reported${kicked} | $perf"
    exit 2
fi

written=$(cl_field written "$line"); http=$(cl_field http "$line")
init=$(cl_field initialized "$line"); sealed=$(cl_field sealed "$line")
snap=$(cl_field snapshot "$line")
if ! [[ $written =~ ^[0-9]+$ && $snap =~ ^[0-9]+$ && $http =~ ^[0-9]{3}$ ]]; then
    echo "OPENBAO REMOTE CRITICAL - $HOST: unreadable marker | $perf"
    exit 2
fi

dur() { if [ "$1" -ge 3600 ]; then cl_hm "$1"; else echo "$(( $1 / 60 ))m"; fi; }
status=0 problems=()
flag() { [ "$1" -gt "$status" ] && status=$1; problems+=("$2"); }

age=$((NOW - written))
if   [ "$age" -ge "$MARKER_CRIT" ]; then flag 2 "last report $(dur "$age") ago: the push or the host is down"
elif [ "$age" -ge "$MARKER_WARN" ]; then flag 1 "last report $(dur "$age") ago: the push is not running"
fi

case $http in
    200) [ "$init" = true ] && [ "$sealed" = false ] \
            || flag 2 "http 200 but initialized=$init sealed=$sealed" ;;
    429|472|473) flag 1 "standby (http $http)" ;;
    501) flag 2 "not initialised (http 501)" ;;
    503) flag 2 "SEALED (http 503)" ;;
    000) flag 2 "no answer from the server" ;;
    *)   flag 2 "unexpected http $http, initialized=$init sealed=$sealed" ;;
esac

if [ "$snap" -eq 0 ]; then
    snap_age=-1
    flag 2 "no raft snapshot at all"
else
    snap_age=$((NOW - snap))
    if   [ "$snap_age" -ge "$SNAP_CRIT" ]; then flag 2 "newest snapshot $(dur "$snap_age") old (crit $(dur "$SNAP_CRIT"))"
    elif [ "$snap_age" -ge "$SNAP_WARN" ]; then flag 1 "newest snapshot $(dur "$snap_age") old (warn $(dur "$SNAP_WARN"))"
    fi
fi

case $status in 0) word=OK;; 1) word=WARNING;; *) word=CRITICAL;; esac
if [ "$status" -eq 0 ]; then
    summary="$HOST: initialized, unsealed, snapshot $(dur "$snap_age") old"
else
    summary="$HOST: ${problems[0]}"
fi
echo "OPENBAO REMOTE $word - $summary (reported $(dur "$age") ago)${kicked} | snapshot_age=${snap_age}s;$SNAP_WARN;$SNAP_CRIT marker_age=${age}s;$MARKER_WARN;$MARKER_CRIT problems=${#problems[@]} $perf"
for p in "${problems[@]}"; do echo "$p"; done
exit $status
