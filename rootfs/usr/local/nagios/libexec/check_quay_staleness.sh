#!/bin/bash
# Check if a Quay.io image is stale
# Usage: check_quay_staleness.sh <org/repo> <max-days> <tag>
#
# Judges the status file quay-collect.sh writes; never calls Quay itself
# (7.1.0, constitution XVI). When the file is missing or older than REFRESH
# (2m, under the 3m check_interval), or does not carry this tag yet, the
# collector is started detached through `podman_exec.sh --detach` in
# nagios-agent-ctr.crunchtools.com and the previous run's file is judged.
#
# Verdicts, unchanged from the live check: WARNING at <max-days> or older, else
# OK. UNKNOWN when Quay has no such tag, when the date cannot be parsed, when
# Quay has not answered for the tag in STALE (10m), and "collector stale" when
# the file is missing or older than STALE.

REPO="${1:-}"
MAX_DAYS="${2:-7}"
TAG="${3:-latest}"

if ! [[ $REPO =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$ && $MAX_DAYS =~ ^[0-9]+$ && $TAG =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "UNKNOWN - usage: check_quay_staleness.sh <org/repo> <max-days> <tag>"
    exit 3
fi

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "UNKNOWN - cannot load collector-lib.sh"; exit 3; }
STATUS=${STATUS:-$STATE_DIR/quay.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/quay-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-120}
STALE=${STALE:-600}

cl_open QUAY "" "$REPO" "$TAG"
item="$REPO:$TAG"
line=$(grep -m1 -E "^QUAY item=${item//./\\.} " <<< "$CL_RAW")
if [ -z "$line" ]; then
    cl_kick "$REPO" "$TAG" && started="collector started" || started="collector could not be started"
    echo "UNKNOWN - $item is not collected yet ($started)"
    exit 3
fi

NOW_EPOCH=$(date +%s)
seen=$(cl_field seen "$line")
since=$(( NOW_EPOCH - ${seen:-0} ))
if [ "$since" -ge "$STALE" ]; then
    echo "UNKNOWN - Quay has not answered for $item in $(cl_hm "$since")${CL_KICKED}"
    exit 3
fi

case "$(cl_field result "$line")" in
    ok) ;;
    notag)   echo "UNKNOWN - No tag data for $item"; exit 3 ;;
    badtime) echo "UNKNOWN - Cannot parse date: $(cl_field msg "$line")"; exit 3 ;;
    *)       echo "UNKNOWN - Cannot query Quay API for $item ($(cl_field msg "$line"))${CL_KICKED}"; exit 3 ;;
esac

MOD_EPOCH=$(cl_field modified "$line")
AGE_DAYS=$(( (NOW_EPOCH - MOD_EPOCH) / 86400 ))

if [ "$AGE_DAYS" -ge "$MAX_DAYS" ]; then
    echo "WARNING - $item is ${AGE_DAYS} days old [threshold: ${MAX_DAYS}d]${CL_KICKED} | age=${AGE_DAYS}d;${MAX_DAYS};;0"
    exit 1
else
    echo "OK - $item is ${AGE_DAYS} days old${CL_KICKED} | age=${AGE_DAYS}d;${MAX_DAYS};;0"
    exit 0
fi
