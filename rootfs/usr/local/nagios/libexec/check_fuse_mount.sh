#!/bin/bash
# check_fuse_mount.sh — a host FUSE mount is mounted and answers a listing (RT #1542)
# Usage: check_fuse_mount.sh <mountpoint> <probe-subdir> [timeout-seconds]
#
# Written for the read-only rclone mount of pCloud at /var/mnt/pcloud that
# mcp-trove indexes. Its failure is quiet: if rclone dies, the empty directory
# stays behind and trove indexes nothing; if rclone lives but pCloud stops
# answering, every read hangs. A green unit state covers neither, so this asks
# the two questions that do:
#
#   CRITICAL  <mountpoint> is not a mountpoint in the host's mount namespace
#   CRITICAL  listing <mountpoint>/<probe-subdir> failed, timed out, or was empty
#   UNKNOWN   the collector could not be run, or answered garbage
#
# HOW IT MEASURES. nrpe cannot see the host mount namespace, so it asks podman
# to run mount-probe-collect.sh as root in this same container; that script's
# header says why. Network-bound, so it belongs on the :5667 pool.

set -uo pipefail

MP="${1:-}"
SUB="${2:-}"
TMO="${3:-10}"
EXEC=${PODMAN_EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/mount-probe-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}

if [ -z "$MP" ] || [ -z "$SUB" ]; then
    echo "FUSE MOUNT UNKNOWN - usage: check_fuse_mount.sh <mountpoint> <probe-subdir> [timeout-seconds]"
    exit 3
fi
valid_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]] && [[ "$1" != *..* ]]; }
if ! valid_path "$MP" || ! valid_path "/$SUB"; then
    echo "FUSE MOUNT UNKNOWN - invalid mountpoint or probe subdir"
    exit 3
fi
if ! [[ "$TMO" =~ ^[0-9]+$ ]] || [ "$TMO" -lt 1 ] || [ "$TMO" -gt 50 ]; then
    echo "FUSE MOUNT UNKNOWN - timeout must be 1-50 seconds"
    exit 3
fi

errf=$(mktemp /tmp/check_fuse_mount.XXXXXX)
trap 'rm -f "$errf"' EXIT
raw=$("$EXEC" "$CONTAINER" "$COLLECT" "$MP" "$SUB" "$TMO" 2>"$errf")
rc=$?
if [ "$rc" -ne 0 ]; then
    err=$(head -c 200 "$errf" | head -n1)
    echo "FUSE MOUNT UNKNOWN - collector exec in $CONTAINER exited $rc${err:+: $err}"
    exit 3
fi

# Anchored extraction, as in check_nightly_dump.sh: a stray framing byte can
# only corrupt the line it lands on.
field() { printf '%s\n' "$raw" | grep -m1 -oE "MPROBE .*\b$1=[^ ]*" | grep -oE "\b$1=[^ ]*" | cut -d= -f2-; }

[ "$(field end)" = 1 ] || { echo "FUSE MOUNT UNKNOWN - collector output truncated or unrecognised"; exit 3; }
error=$(field error)
[ -n "$error" ] && { echo "FUSE MOUNT UNKNOWN - collector reported: $error"; exit 3; }

if [ "$(field mounted)" != 1 ]; then
    echo "FUSE MOUNT CRITICAL - $MP is not a mountpoint | entries=0;;1:;0 elapsed=0s;;$TMO;0"
    exit 2
fi

fstype=$(field fstype)
lrc=$(field list_rc); entries=$(field entries); ms=$(field ms)
if ! [[ "$lrc" =~ ^[0-9]+$ && "$entries" =~ ^[0-9]+$ && "$ms" =~ ^[0-9]+$ ]]; then
    echo "FUSE MOUNT UNKNOWN - collector returned no listing result"
    exit 3
fi
secs=$(printf '%d.%02d' $(( ms / 1000 )) $(( ms % 1000 / 10 )))
perf="entries=${entries};;1:;0 elapsed=${secs}s;;$TMO;0"

# timeout exits 124 on TERM and 137 when it had to KILL.
case "$lrc" in
    0)       ;;
    124|137) echo "FUSE MOUNT CRITICAL - listing $MP/$SUB timed out after ${TMO}s ($fstype) | $perf"; exit 2 ;;
    *)       echo "FUSE MOUNT CRITICAL - listing $MP/$SUB failed, exit $lrc ($fstype) | $perf"; exit 2 ;;
esac

if [ "$entries" -eq 0 ]; then
    echo "FUSE MOUNT CRITICAL - $MP/$SUB lists empty ($fstype) | $perf"
    exit 2
fi

echo "FUSE MOUNT OK - $MP ($fstype): $SUB lists $entries entries in ${secs}s | $perf"
exit 0
