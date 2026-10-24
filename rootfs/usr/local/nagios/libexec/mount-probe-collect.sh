#!/bin/bash
# mount-probe-collect.sh — is a host FUSE mount there, and does it answer? (RT #1542)
# Usage: mount-probe-collect.sh <mountpoint> <probe-subdir> [timeout-seconds]
#
# WHY ROOT. The mount lives in the host's mount namespace, which this container
# does not share: /var/mnt is not bind-mounted in, and adding it would need
# rslave propagation to survive the rclone unit restarting. --pid=host gives us
# /proc/1/root instead, the host's root as PID 1 sees it, but walking that link
# needs ptrace rights over PID 1, which nrpe does not have. So
# check_fuse_mount.sh runs unprivileged and shells back through podman_exec.sh
# to run this as root in this same container, the split srv-drift-collect.sh
# and srv-nightly-dump-collect.sh already use.
#
# WHAT IT MEASURES. Two facts, in order:
#   1. Is <mountpoint> in PID 1's mountinfo, and with what fstype. A dead rclone
#      leaves the empty directory behind, so the path existing proves nothing.
#   2. Does a listing of <mountpoint>/<probe-subdir> come back inside the
#      timeout. A live FUSE daemon whose remote is gone answers mountinfo fine
#      and then hangs every read. timeout -k sends SIGKILL after a grace
#      period, because FUSE waits are killable but not always interruptible.
# Only an entry count crosses the boundary, never a filename.
#
# OUTPUT. "MPROBE key=value" lines ending with MPROBE end=1, self-anchored for
# the same reason as srv-nightly-dump-collect.sh: podman_exec.sh strips stream
# framing byte-wise. All policy lives in the plugin; this only reports facts.

set -uo pipefail

MP="${1:-}"
SUB="${2:-}"
TMO="${3:-10}"
PROC_ROOT=${PROC_ROOT:-/proc/1}

emit() { printf 'MPROBE %s\n' "$1"; }
bail() { emit "error=$1"; emit "end=1"; exit 0; }

# Same path rule as the plugin: absolute, plain characters, no "..".
valid_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]] && [[ "$1" != *..* ]]; }
valid_path "$MP" || bail invalid_mountpoint
valid_path "/$SUB" || bail invalid_subdir
[[ "$TMO" =~ ^[0-9]+$ ]] && [ "$TMO" -ge 1 ] && [ "$TMO" -le 50 ] || bail invalid_timeout
[ -r "$PROC_ROOT/mountinfo" ] || bail no_host_mountinfo

# mountinfo field 5 is the mount point; the fstype follows the "-" separator.
# The last match wins, so a mount stacked over another reports the top one.
fstype=$(awk -v mp="$MP" '$5 == mp { for (i = 7; i <= NF; i++) if ($i == "-") { t = $(i + 1); break } } END { print t }' "$PROC_ROOT/mountinfo")

if [ -z "$fstype" ]; then
    emit "mounted=0"
    emit "end=1"
    exit 0
fi
emit "mounted=1 fstype=$fstype"

# The whole directory is counted on purpose. rclone answers the first readdir
# by fetching the full remote listing into its dir cache, so stopping at one
# entry would save no network work, and the count makes useful perfdata. Keep
# the probe dir small (a top-level folder, not a photo dump). find, not ls, so
# nothing is sorted and no stat is issued per entry.
start=$(date +%s%N)
entries=$(set -o pipefail; timeout -k 2 "$TMO" find "$PROC_ROOT/root$MP/$SUB" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null | wc -c)
rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
emit "list_rc=$rc entries=${entries:-0} ms=$ms"
emit "end=1"
