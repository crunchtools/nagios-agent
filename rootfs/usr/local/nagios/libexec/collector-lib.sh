# shellcheck shell=bash
# collector-lib.sh — shared half of the collector + status-file pattern (7.1.0)
#
# Sourced, never executed. Constitution XVI: a check whose read can be slow (an
# outside API, remote storage) does not make that read inline. A collector does
# the reads with a generous budget and writes a status file atomically under
# STATE_DIR; the check judges the file, starts the collector detached when the
# file is older than REFRESH, and is UNKNOWN "collector stale" only when the
# file is missing, unreadable or older than STALE. 7.0.0 wrote that once for
# the pCloud backup checks; 7.1.0 moved Cloudflare, Quay, registry drift and
# Google OAuth onto it, so the pieces they share live here.
#
# Every status file has the same frame, with one PREFIX per family:
#   <PREFIX> generated=<epoch> ...
#   <PREFIX> ...                     item lines, family-specific
#   <PREFIX> end=1                   proves the file was written whole
#
# Callers set, before calling the check-side helpers:
#   STATUS     the status file
#   COLLECT    the collector's path inside CONTAINER
#   CONTAINER  where the collector runs (it runs as root there, via the exec)
#   REFRESH    seconds: start a collector run when the file is this old
#   STALE      seconds: older than this and the file is not trusted

STATE_DIR=${STATE_DIR:-/var/lib/nagios-agent}
EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}

# ---- collector side ---------------------------------------------------------

# cl_lock <name>: take this collector's lock or exit. Exits 0 when another run
# holds it (that run will write the file) and 3 when the state dir is unusable.
cl_lock() {
    mkdir -p "$STATE_DIR" || exit 3
    exec 9>"$STATE_DIR/.$1.lock" || exit 3
    flock -n 9 || exit 0
}

# cl_publish <file> <status>: atomic replace, world-readable for the nrpe user.
# The temp file sits beside the target so the rename never crosses a mount.
cl_publish() {
    local out="$2.tmp.$$"
    cp "$1" "$out"     || { echo "publish: cannot write $out" >&2; rm -f "$out"; return 1; }
    chmod 0644 "$out"  || { echo "publish: cannot chmod $out" >&2; rm -f "$out"; return 1; }
    mv -f "$out" "$2"  || { echo "publish: cannot rename $out to $2" >&2; rm -f "$out"; return 1; }
}

# cl_previous <status> <grep -E pattern>: matching lines of the current file.
cl_previous() {
    [ -r "$1" ] && grep -E "$2" "$1"
}

# cl_clean <text>: printable ASCII only, no spaces or pipes, at most 80 chars.
# For message fields that go into a space-separated status line.
cl_clean() {
    printf '%s' "$1" | tr -cd '\040-\176' | tr ' |' '_/' | cut -c1-80
}

# ---- check side -------------------------------------------------------------

# cl_field <name> <line>: value of name= in a status line, in-shell.
cl_field() {
    local re="(^| )$1=([^ ]*)"
    [[ $2 =~ $re ]] && printf '%s' "${BASH_REMATCH[2]}"
}

# cl_hm <seconds>: "2h5m"
cl_hm() { echo "$(( $1 / 3600 ))h$(( $1 % 3600 / 60 ))m"; }

# cl_kick [args...]: start COLLECT detached in CONTAINER. 0 once podman took it.
cl_kick() { "$EXEC" --detach "$CONTAINER" "$COLLECT" "$@" >/dev/null 2>&1; }

# cl_open <PREFIX> <head> [collector args...]
#
# Loads STATUS for a check. On return CL_RAW holds the file, CL_AGE its age in
# seconds and CL_KICKED a note to append when a due kick could not be started.
# Starts the collector when the file is due (REFRESH). Prints the UNKNOWN line
# itself and exits 3 when the file is missing, truncated or older than STALE;
# <head> is the check's own status prefix up to the verdict, e.g. "BACKUPS" or
# "" for checks whose first line is a bare "UNKNOWN - ...".
cl_open() {
    local prefix=$1 head=${2:+$2 } started generated
    shift 2
    if [ ! -r "$STATUS" ]; then
        cl_kick "$@" && started="collector started" || started="collector could not be started"
        echo "${head}UNKNOWN - collector stale: no status file at $STATUS ($started)"
        exit 3
    fi
    CL_RAW=$(cat "$STATUS")
    generated=""
    [[ $CL_RAW =~ (^|$'\n')"$prefix generated="([0-9]+) ]] && generated=${BASH_REMATCH[2]}
    grep -qx "$prefix end=1" <<< "$CL_RAW" || generated=""
    if [ -z "$generated" ]; then
        cl_kick "$@"
        echo "${head}UNKNOWN - collector stale: $STATUS is truncated or unrecognised"
        exit 3
    fi
    CL_AGE=$(( $(date +%s) - generated ))
    CL_KICKED=""
    if [ "$CL_AGE" -ge "$REFRESH" ]; then cl_kick "$@" || CL_KICKED=" (collector could not be started)"; fi
    if [ "$CL_AGE" -ge "$STALE" ]; then
        echo "${head}UNKNOWN - collector stale: last collection $(cl_hm "$CL_AGE") ago${CL_KICKED} | collected_age=${CL_AGE}s;;${STALE}"
        exit 3
    fi
}
