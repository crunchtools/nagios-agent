#!/bin/bash
# config-drift-repos-collect.sh — cross-repo config drift reads off the NRPE
# hot path (7.2.0)
#
# THE PROBLEM. check_config_drift.sh made ~30 shallow clones from GitHub on
# every run, inside check_nrpe's ceiling, with a 10s per-clone bound that was
# only there to stay under it. Constitution XVI moves reads like that into a
# collector.
#
# THE SPLIT. This script does both reads the plugin used to make and the
# matching between them (moved here unchanged; check_config_drift.sh's header
# says what is compared and why):
#
#   1. the fingerprint of the deployed tree, from config-drift-collect.sh run
#      as root through podman_exec.sh in nagios-agent.crunchtools.com, which
#      has /var/srv mounted, bounded by FP_TIMEOUT (60s). Nothing privileged
#      touches the network.
#   2. one blobless bare clone per rival repo named in config-sources.conf,
#      JOBS (16) at a time, NET_TIMEOUT (30s) a clone, inside BUDGET (180s).
#
# It runs in nagios-agent-ctr.crunchtools.com, started detached by
# check_config_drift.sh when config-drift.status is older than REFRESH (30m,
# under the 60m check_interval). A flock stops overlapping runs.
#
# LAST GOOD ANSWERS. Each repo's tree and image-path list is cached under
# $STATE_DIR/config-drift-repos/ with the time it was read. A clone that fails
# reuses the cached tree, and the repo= line keeps its old seen, so the plugin
# can count a repo read more than STALE ago as unreadable and drop its
# findings. A fingerprint exec that fails leaves the previous status file in
# place (it ages out in the plugin); with no previous file it records why.
#
# WHAT IT WRITES, $STATE_DIR/config-drift.status, replaced atomically:
#   CFGDRIFT generated=<epoch> elapsed=<s> deployed=<n> unpublished=<n>
#   CFGDRIFT generated=<epoch> error=<reason>
#   CFGDRIFT unpublished_list=<basename,...>
#   CFGDRIFT repo=<name> seen=<epoch|0>
#   CFGDRIFT unmapped=<service>
#   CFGDRIFT item kind=DIVERGENT|DUPLICATE|SECRET|AMBIGUOUS repo=<name> base=<basename> file=<repo>/<path>
#   CFGDRIFT end=1
#
# Paths and basenames are printable ASCII with spaces and pipes replaced.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || exit 3

CONF=${CONFIG_DRIFT_CONF:-/etc/nagios/config-sources.conf}
ORG=${CONFIG_DRIFT_ORG:-crunchtools}
GIT_HOST=${CONFIG_DRIFT_GIT_HOST:-https://github.com}
NET_TIMEOUT=${CONFIG_DRIFT_TIMEOUT:-30}
JOBS=${CONFIG_DRIFT_JOBS:-16}
BUDGET=${BUDGET:-180}
FP_CONTAINER=${FP_CONTAINER:-nagios-agent.crunchtools.com}
FINGERPRINT=${FINGERPRINT:-/usr/local/nagios/libexec/config-drift-collect.sh}
FP_TIMEOUT=${CONFIG_DRIFT_FP_TIMEOUT:-60}
STATUS="$STATE_DIR/config-drift.status"
CACHE="$STATE_DIR/config-drift-repos"

# Bare git against something it cannot read BLOCKS on a credential prompt
# rather than failing. Refuse the prompt, and bound every call with timeout.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

cl_lock config-drift

START=$(date +%s)
TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

publish_error() {
    printf 'CFGDRIFT generated=%s error=%s\nCFGDRIFT end=1\n' "$START" "$(cl_clean "$1")" > "$TMP/status"
    cl_publish "$TMP/status" "$STATUS"
    exit 0
}

# A read that may succeed next time: keep an earlier answer if there is one.
transient() {
    if [ -r "$STATUS" ]; then
        echo "config-drift-repos-collect: $1, keeping the previous status file" >&2
        exit 1
    fi
    publish_error "$1"
}

clean_path() { printf '%s' "$1" | tr -cd '\040-\176' | tr ' |' '_/'; }

[ -r "$CONF" ] || publish_error conf_unreadable
mkdir -p "$CACHE" || publish_error cache_unwritable

# ---- 1. the deployed fingerprint --------------------------------------------

# Bounded like every other read here: a stalled exec must not hold the lock
# and keep every later run out. timeout exits 124 when it fires.
raw=$(timeout "$FP_TIMEOUT" "$EXEC" "$FP_CONTAINER" "$FINGERPRINT" 2>/dev/null 9>&-)
rc=$?
[ "$rc" -eq 0 ] || transient "fingerprint exec in $FP_CONTAINER exited $rc"

# Anchored extraction, not a line parse: podman_exec.sh strips the libpod
# stream framing byte-wise and a stray printable byte can survive it.
field() { printf '%s\n' "$raw" | grep -m1 -oE "CFGDRIFT $1=.*" | cut -d= -f2- ; }
fields() { printf '%s\n' "$raw" | grep -oE "CFGDRIFT $1=.*" | cut -d= -f2- ; }

[ -n "$(field end)" ] || transient "fingerprint output truncated or unrecognised"
error=$(field error)
[ -n "$error" ] && publish_error "$error"

deployed=$(field deployed)
unpublished=$(field unpublished)
unpublished_list=$(field unpublished_list)
for v in "$deployed" "$unpublished"; do
    case "$v" in ''|*[!0-9]*) transient "fingerprint returned a non-numeric count" ;; esac
done

# Deployed path -> content hash, and the set of deployed secret-bearing paths.
# Each line is validated rather than trusted: one framing byte surviving the
# strip would otherwise turn into a fabricated mismatch.
declare -A DISK=()
declare -A SECRET=()
corrupt=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        */config/*:[0-9a-f]*) : ;;
        *) corrupt=$(( corrupt + 1 )); continue ;;
    esac
    sha=${line##*:}
    path=${line%:*}
    case "$sha" in *[!0-9a-f]*) corrupt=$(( corrupt + 1 )); continue ;; esac
    [ "${#sha}" -eq 40 ] || { corrupt=$(( corrupt + 1 )); continue; }
    DISK["$path"]=$sha
done < <(fields blob)

while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in */config/*) SECRET["$line"]=1 ;; *) corrupt=$(( corrupt + 1 )) ;; esac
done < <(fields secret)

[ "$corrupt" -eq 0 ] || transient "${corrupt} unparseable fingerprint line(s)"
[ "${#DISK[@]}" -gt 0 ] || publish_error "fingerprint held no config files"

# ---- 2. the rival repos ------------------------------------------------------

# Which service maps to which rival repo. "none" is a deliberate answer;
# absence is not. The repo field is a comma-separated list. Each name becomes a
# path and a clone argument, so validate the RAW field before the deliberately
# unquoted split (a bare "*" would otherwise glob), then each piece.
declare -A RIVAL=()
while read -r svc repo _; do
    case "$svc" in ''|\#*) continue ;; esac
    [ -n "${repo:-}" ] || continue
    case "$repo" in *[!A-Za-z0-9._,-]*) continue ;; esac
    bad=0
    for one in ${repo//,/ }; do
        case "$one" in ''|.|..) bad=1 ;; esac
    done
    [ "$bad" -eq 0 ] || continue
    RIVAL["$svc"]=$repo
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

unmapped=""
declare -A NEEDED=()
for path in "${!DISK[@]}" "${!SECRET[@]}"; do
    svc=${path%%/*}
    case "${RIVAL[$svc]:-}" in
        '')   case " $unmapped " in *" $svc "*) : ;; *) unmapped="$unmapped $svc" ;; esac ;;
        none) : ;;
        *)    for one in ${RIVAL[$svc]//,/ }; do NEEDED["$one"]=1; done ;;
    esac
done

# Every path the image bakes in, one per line, for the repo just cloned.
# Reading the Containerfile from the blobless clone fetches exactly that blob.
# A missing Containerfile is not a failure: rootfs/ alone is still correct.
image_paths() {
    local repo=$1 out
    printf 'rootfs/\n'
    out=$(timeout "$NET_TIMEOUT" git --git-dir="${WORK}/${repo}.git" show HEAD:Containerfile 2>/dev/null) || return 0
    printf '%s\n' "$out" | awk '
        toupper($1) != "COPY" && toupper($1) != "ADD" { next }
        {
            # Drop the directive, then every flag. --from= copies out of a
            # build stage rather than out of the repo.
            from_stage = 0
            n = 0
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^--from=/) { from_stage = 1; break }
                if ($i ~ /^--/) continue
                args[++n] = $i
            }
            if (from_stage || n < 2) { n = 0; delete args; next }
            # The last argument is the destination; the rest are repo sources.
            for (i = 1; i < n; i++) print args[i]
            n = 0; delete args
        }'
    return 0
}

# Clone one repo and, only when everything worked, replace its cache entry.
# The rename keeps a reader from seeing a half-written tree.
fetch_tree() {
    local repo=$1
    if timeout "$NET_TIMEOUT" git clone -q --filter=blob:none --bare --depth 1 \
         "${GIT_HOST}/${ORG}/${repo}" "${WORK}/${repo}.git" 2>/dev/null \
       && git --git-dir="${WORK}/${repo}.git" ls-tree -r HEAD \
            --format='%(objectname) %(path)' > "${WORK}/${repo}.tree" 2>/dev/null \
       && [ -s "${WORK}/${repo}.tree" ]; then
        image_paths "$repo" > "${WORK}/${repo}.image" 2>/dev/null
        mv -f "${WORK}/${repo}.tree" "${CACHE}/${repo}.tree" \
          && mv -f "${WORK}/${repo}.image" "${CACHE}/${repo}.image" \
          && date +%s > "${CACHE}/${repo}.seen"
    fi
    rm -rf "${WORK}/${repo}.git"
}
export -f fetch_tree image_paths
WORK="$TMP/work"
mkdir -p "$WORK"
export GIT_HOST ORG WORK CACHE NET_TIMEOUT

# Workers get no copy of the lock (9>&-): a clone outliving the budget inside
# its own timeout must not keep the next run out.
if [ "${#NEEDED[@]}" -gt 0 ]; then
    printf '%s\n' "${!NEEDED[@]}" \
      | timeout "$BUDGET" xargs -P "$JOBS" -I{} bash -c 'fetch_tree "$@"' _ {} >/dev/null 2>&1 9>&-
fi

# ---- 3. the matching ---------------------------------------------------------

# Longest common trailing path suffix, in components. The deployed
# config/temporal/config.yaml scores 2 against rootfs/etc/temporal/config.yaml
# and 1 against .gemini/config.yaml.
suffix_score() {
    local -a a b
    local n=0 i j
    IFS=/ read -ra a <<< "$1"
    IFS=/ read -ra b <<< "$2"
    i=$(( ${#a[@]} - 1 )); j=$(( ${#b[@]} - 1 ))
    while [ $i -ge 0 ] && [ $j -ge 0 ] && [ "${a[$i]}" = "${b[$j]}" ]; do
        n=$(( n + 1 )); i=$(( i - 1 )); j=$(( j - 1 ))
    done
    printf '%s' "$n"
}

: > "$TMP/items"
for path in "${!DISK[@]}" "${!SECRET[@]}"; do
    svc=${path%%/*}
    base=${path##*/}
    repos=${RIVAL[$svc]:-}
    [ -n "$repos" ] && [ "$repos" != none ] || continue

    # A build file is not configuration.
    case "$base" in Containerfile|Dockerfile|.containerignore) continue ;; esac

    # Scored across every rival at once, so a file claimed by two repos is
    # reported once, against its single best counterpart. A repo never read
    # has no cache entry and simply takes no part.
    best=0; best_path=""; best_sha=""; best_repo=""; ties=0
    for repo in ${repos//,/ }; do
        [ -s "${CACHE}/${repo}.tree" ] || continue
        while read -r rsha rpath; do
            [ "${rpath##*/}" = "$base" ] || continue
            case "$rpath" in docs/*|tests/*|examples/*) continue ;; esac
            score=$(suffix_score "$path" "$rpath")
            if [ "$score" -gt "$best" ]; then
                best=$score; best_path=$rpath; best_sha=$rsha; best_repo=$repo; ties=1
            elif [ "$score" -eq "$best" ] && [ "$best" -gt 0 ]; then
                ties=$(( ties + 1 ))
            fi
        done < "${CACHE}/${repo}.tree"
    done

    [ "$best" -gt 0 ] || continue
    repo=$best_repo

    if [ "$ties" -gt 1 ]; then
        kind=AMBIGUOUS; best_path=$base
    else
        # Image content, not a second home for deployed config. A COPY of a
        # directory covers everything under it, of a file just that file.
        baked=0
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            case "$ip" in
                */) case "$best_path" in "$ip"*) baked=1; break ;; esac ;;
                *)  case "$best_path" in "$ip"|"$ip"/*) baked=1; break ;; esac ;;
            esac
        done < "${CACHE}/${repo}.image"
        [ "$baked" -eq 0 ] || continue

        if [ -n "${SECRET[$path]:-}" ]; then
            kind=SECRET
        elif [ "$best_sha" = "${DISK[$path]:-}" ]; then
            kind=DUPLICATE
        else
            kind=DIVERGENT
        fi
    fi
    printf 'CFGDRIFT item kind=%s repo=%s base=%s file=%s/%s\n' \
        "$kind" "$repo" "$(clean_path "$base")" "$repo" "$(clean_path "$best_path")" >> "$TMP/items"
done

{
    echo "CFGDRIFT generated=$START elapsed=$(( $(date +%s) - START )) deployed=$deployed unpublished=$unpublished"
    echo "CFGDRIFT unpublished_list=$(clean_path "$unpublished_list")"
    for repo in $(printf '%s\n' "${!NEEDED[@]}" | sort); do
        seen=$(cat "${CACHE}/${repo}.seen" 2>/dev/null)
        case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
        [ -s "${CACHE}/${repo}.tree" ] || seen=0
        echo "CFGDRIFT repo=$repo seen=$seen"
    done
    read -ra svcs <<< "$unmapped"
    [ "${#svcs[@]}" -gt 0 ] && printf '%s\n' "${svcs[@]}" | sort | while IFS= read -r svc; do
        echo "CFGDRIFT unmapped=$(clean_path "$svc")"
    done
    sort "$TMP/items"
    echo "CFGDRIFT end=1"
} > "$TMP/status"
cl_publish "$TMP/status" "$STATUS"
