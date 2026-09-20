#!/bin/bash
#############################################################################
# check_syslog_source_freshness.sh — per-source log-loss detector
#
# Usage: check_syslog_source_freshness.sh [LOG_ROOT] [LAG_MIN] [NET_WARN] [NET_CRIT] [EXCLUDE_CSV]
#
# Why this exists, given two syslog checks already run:
#
#   check_syslog_freshness.sh takes the newest mtime across ALL sources, so one
#   busy container keeps it green while any individual source silently stops
#   landing lines. check_syslog_coverage.sh proves a source DIRECTORY exists and
#   that the log driver is journald — a directory survives a stall untouched.
#   Neither can see one container go dark. That is the gap this closes.
#
# The hard part is separating "went dark" from "idle". With only the log
# directory to look at they are indistinguishable, which is exactly why the
# coverage check reports quiet containers without paging. So this check gets a
# second, INDEPENDENT opinion on what each container actually emitted.
#
# lotor has two ingest paths and they need different evidence:
#
#   journald path — conmon captures container stdout and imjournal feeds the
#     collector. `podman logs --tail 1` is an independent view of what the
#     container really emitted, so a stall becomes provable: conmon holds output
#     newer than anything that reached /logs. Idle containers cannot false-alarm,
#     because an idle container has no fresh conmon output either. No per-service
#     threshold tuning, and no exclusion list needed for quiet services.
#
#   network path — systemd-based containers whose internal logs never reach
#     conmon (podman has no syslog log driver); they speak syslog straight to
#     :514. `podman logs` is EMPTY for these, so no second opinion exists and
#     staleness is the only available signal. These are the continuously chatty
#     web services, so a generous flat threshold is safe here — and would NOT be
#     safe on the journald side, where idle is normal.
#
# The two are told apart by the host field the collector writes. rsyslog sets
# $.source = $hostname for network senders, so host == source; journald senders
# carry lotor's hostname instead. Comparing the two fields needs no hardcoded
# hostname and no per-container configuration.
#
# Exit: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
#############################################################################

LOG_ROOT="${1:-/srv/syslog.crunchtools.com/data/logs}"
LAG_MIN="${2:-15}"      # journald: minutes conmon may lead /logs before it is a stall
NET_WARN="${3:-120}"    # network senders: staleness warn
NET_CRIT="${4:-360}"    # network senders: staleness critical
FRESH_MIN="${5:-30}"    # journald: how recently conmon must have output to judge at all
EXCLUDE_CSV="${6:-}"    # comma-separated source names to skip entirely

SOCK=/run/podman/podman.sock
API=http://localhost/v5.0.0

if [ ! -d "$LOG_ROOT" ]; then
    echo "UNKNOWN - syslog log root $LOG_ROOT does not exist"
    exit 3
fi
if [ ! -S "$SOCK" ]; then
    echo "UNKNOWN - podman socket $SOCK not available; cannot enumerate containers"
    exit 3
fi

names=$(curl -s --unix-socket "$SOCK" "$API/libpod/containers/json" --max-time 10 2>/dev/null \
        | grep -o '"Names":\[[^]]*\]' | grep -o '"[^"]*"' | grep -v Names | tr -d '"')

if [ -z "$names" ]; then
    echo "UNKNOWN - could not enumerate containers via $SOCK"
    exit 3
fi

now=$(date +%s)

stalled=""      # journald: conmon has output that never landed — provable loss
dark=""         # network: nothing received for too long
dark_warn=""
nodir=""        # running, but no log directory at all
unproven=""     # journald, stale, but conmon has nothing to compare (idle/rotated)
checked=0
skipped=0

# Last log line a container actually emitted, per conmon. Empty for network
# senders and for anything whose journal entries have already rotated away.
# The 8-byte frame header podman prepends can contain printable bytes, so the
# timestamp is matched anywhere in the line rather than anchored to its start.
conmon_last_epoch() {
    local ts
    ts=$(curl -s --unix-socket "$SOCK" \
            "$API/libpod/containers/$1/logs?stdout=true&stderr=true&tail=1&timestamps=true" \
            --max-time 5 2>/dev/null \
         | tr -d '\000-\010\013\014\016-\037' \
         | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[0-9.]*[+-][0-9]{2}:[0-9]{2}' \
         | head -1)
    [ -z "$ts" ] && return 1
    date -d "$ts" +%s 2>/dev/null
}

for name in $names; do
    case ",$EXCLUDE_CSV," in
        *",$name,"*) skipped=$((skipped + 1)); continue ;;
    esac

    dir="$LOG_ROOT/$name"
    if [ ! -d "$dir" ]; then
        nodir="$nodir $name"
        continue
    fi

    # Newest log for this source. .gz is included so a source silent longer than
    # the 2-day compression window still yields a real age instead of "nothing".
    newest=$(find "$dir" -type f \( -name '*.log' -o -name '*.log.gz' \) \
                  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)
    if [ -z "$newest" ]; then
        nodir="$nodir $name(empty)"
        continue
    fi

    checked=$((checked + 1))
    mtime=${newest%% *}; mtime=${mtime%.*}
    path=${newest#* }
    age_min=$(( (now - mtime) / 60 ))

    # Classify the ingest path from the host field the collector stamped.
    # zcat -f reads plain and gzipped alike.
    host=$(zcat -f "$path" 2>/dev/null | tail -1 | awk '{print $2}')

    if [ "$host" = "$name" ]; then
        # Network sender: staleness is the only signal available.
        if [ "$age_min" -ge "$NET_CRIT" ]; then
            dark="$dark $name(${age_min}m)"
        elif [ "$age_min" -ge "$NET_WARN" ]; then
            dark_warn="$dark_warn $name(${age_min}m)"
        fi
    else
        # journald sender. Fresh in /logs means no stall is possible, so skip the
        # API round trip — this keeps the common case to filesystem stats only.
        [ "$age_min" -le "$LAG_MIN" ] && continue

        if c_epoch=$(conmon_last_epoch "$name") && [ -n "$c_epoch" ]; then
            conmon_age=$(( (now - c_epoch) / 60 ))
            lag_min=$(( (c_epoch - mtime) / 60 ))
            # Both conditions matter. A big lag alone is not a stall: conmon keeps
            # history from before the host moved off imjournal, and those lines
            # were never collected and never will be, so the gap is permanent and
            # says nothing about now. Only a container that is emitting CURRENTLY
            # while its output fails to land is actually broken.
            if [ "$conmon_age" -le "$FRESH_MIN" ] && [ "$lag_min" -gt "$LAG_MIN" ]; then
                stalled="$stalled $name(${lag_min}m)"
            fi
        else
            # Idle, or the journal rotated past it. Not provable either way, so
            # it is reported but never paged — the same discipline the coverage
            # check uses for containers with no logs yet.
            unproven="$unproven $name(${age_min}m)"
        fi
    fi
done

n_stalled=$(printf '%s' "$stalled" | wc -w)
n_dark=$(printf '%s' "$dark" | wc -w)
n_darkw=$(printf '%s' "$dark_warn" | wc -w)
n_nodir=$(printf '%s' "$nodir" | wc -w)
n_unproven=$(printf '%s' "$unproven" | wc -w)

perf="stalled=$n_stalled;1;1;0 dark=$n_dark;1;1;0 dark_warn=$n_darkw checked=$checked unproven=$n_unproven nodir=$n_nodir"

if [ "$n_stalled" -gt 0 ]; then
    echo "CRITICAL - $n_stalled source(s) emitting but not landing in syslog:$stalled | $perf"
    exit 2
fi
if [ "$n_dark" -gt 0 ]; then
    echo "CRITICAL - $n_dark network source(s) dark >${NET_CRIT}m:$dark | $perf"
    exit 2
fi
if [ "$n_darkw" -gt 0 ]; then
    echo "WARNING - $n_darkw network source(s) quiet >${NET_WARN}m:$dark_warn | $perf"
    exit 1
fi

extra=""
[ "$n_nodir" -gt 0 ] && extra="$extra, $n_nodir with no logs yet"
[ "$n_unproven" -gt 0 ] && extra="$extra, $n_unproven idle (unprovable)"
echo "OK - $checked source(s) landing normally$extra | $perf"
exit 0
