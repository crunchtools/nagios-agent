#!/bin/bash
# config-drift-collect.sh — fingerprint the deployed config tree (RT #1498)
#
# The failure this exists to catch, on 2026-09-20: proxy.crunchtools.com.conf
# was tracked by TWO git repos that had silently diverged. The deployed copy
# lived in lotor.dc3.crunchtools.com-srv; a stale reference copy lived in
# crunchtools/proxy, four vhosts behind. Syncing the host file from the wrong
# one deleted trentina, mcp-gw-personal, mcp-gw-work and mcp-pcloud and took
# josui's gateway to HTTP 403 until the backup was restored.
#
# check_git_drift.sh could not have seen that coming. It measures whether /srv
# has drifted from ITS OWN origin -- dirty files, unpushed commits. It has no
# idea a second repo exists, let alone that the second repo disagrees. A file
# with two git homes is an outage waiting for someone to pick the wrong one,
# and Constitution XIV says it should not have two: container configuration
# lives in /srv/<service>/config/ and is bind-mounted, full stop.
#
# WHAT THIS PUBLISHES, and why it is only half the job. Reading /var/srv needs
# root -- see the header of srv-drift-collect.sh, the split is load-bearing --
# but comparing against GitHub needs only the network. So this script does the
# privileged half: it publishes a fingerprint of the deployed tree. The
# unprivileged half, check_config_drift.sh, fetches the rival repos and does
# the comparison. Nothing privileged ever touches the network.
#
# WHAT CROSSES THE BOUNDARY. Paths and git blob SHAs, never contents. A blob
# SHA identifies a file without revealing it; that is the whole point of
# publishing one instead of the file. Even so, files that carry secrets --
# .env, keys, certs, wp-config.php and friends -- get their path emitted with
# NO hash at all. There is nothing to compare for them: a deployed secret file
# that also lives in a public repo is a Constitution XVII violation whether the
# two copies match or not, so presence is the finding and the hash would only
# hand an attacker an offline oracle for guessing the contents.
#
# OUTPUT. One "CFGDRIFT key=value" line per field, ending with CFGDRIFT end=1,
# for the same reason srv-drift-collect.sh does it: podman_exec.sh strips the
# libpod stream framing byte-wise and a frame header's length byte can survive
# as a stray printable character. Anchoring every field to a sentinel keeps one
# stray byte from corrupting a parse, and end=1 proves nothing was truncated.
#
# No `git fetch`: lotor is the only writer, so the local origin/master ref is
# an honest answer to "what does GitHub hold?" without putting SSH in a
# monitoring path.

set -uo pipefail

REPO=${CONFIG_DRIFT_REPO:-/var/srv}
REF=${CONFIG_DRIFT_REF:-origin/master}
NOW=$(date +%s)

emit() { printf 'CFGDRIFT %s=%s\n' "$1" "$2"; }

bail() {
  emit generated "$NOW"
  emit error "$1"
  emit end 1
  exit 0
}

command -v git >/dev/null 2>&1 || bail git_missing
[ -d "$REPO/.git" ] || bail repo_not_mounted
cd "$REPO" || bail repo_unreadable

git --no-optional-locks rev-parse --verify -q "$REF" >/dev/null 2>&1 || bail ref_missing

# Files whose content must never be compared or hashed across the boundary.
# Matched on the basename, because the extension is what tells you a file holds
# values rather than structure. Keep this list in step with Constitution XVII.
is_secret() {
  case "$1" in
    *.env|env|*.key|*.crt|*.pem|*.p12|*.token|*.secret|.netrc|htpasswd|\
    wp-config.php|LocalSettings.php|RT_SiteConfig.pm) return 0 ;;
    *) return 1 ;;
  esac
}

# The deployed set is the tracked files under any service's config/ directory.
# Untracked files there are gitignored certs and env files -- already outside
# git, so "which repo owns them" is not a question that has an answer.
mapfile -d '' tracked < <(git --no-optional-locks ls-files -z -- '*/config/*' 2>/dev/null)
[ "${#tracked[@]}" -gt 0 ] || bail no_config_files

# What GitHub holds for the same paths. One ls-tree instead of one rev-parse
# per file: 265 files is 265 forks otherwise, and this runs every hour.
declare -A committed=()
while IFS=' ' read -r path sha; do
  [ -n "$path" ] || continue
  committed["$path"]=$sha
done < <(git --no-optional-locks ls-tree -r "$REF" --format='%(path) %(objectname)' 2>/dev/null \
         | grep '/config/')

deployed=0
skipped=0
unpublished=0
unpublished_list=""
blobs=""
secrets=""

# Hash the worktree copies in one process. --stdin-paths is the difference
# between one fork and several hundred, and it prints SHAs in the order the
# paths went in, which is the only reason this can be zipped back together.
#
# Secret-bearing files are hashed too -- the unpublished comparison below is
# worth most precisely on them, and asking the git INDEX instead would miss a
# live edit that was never `git add`ed. The hash simply never leaves this
# script for those paths.
declare -a hashable=()
for path in "${tracked[@]}"; do
  [ -n "$path" ] || continue
  # A path with whitespace would desync --stdin-paths and corrupt every SHA
  # after it. None exist today; count them rather than guess at them.
  case "$path" in *[[:space:]]*) skipped=$(( skipped + 1 )); continue ;; esac
  deployed=$(( deployed + 1 ))
  [ -f "$path" ] || { skipped=$(( skipped + 1 )); continue; }
  hashable+=("$path")
done

if [ "${#hashable[@]}" -gt 0 ]; then
  mapfile -t hashes < <(printf '%s\n' "${hashable[@]}" | git --no-optional-locks hash-object --stdin-paths 2>/dev/null)
  [ "${#hashes[@]}" -eq "${#hashable[@]}" ] || bail hash_object_desync

  for i in "${!hashable[@]}"; do
    path=${hashable[$i]}
    disk=${hashes[$i]}
    case "$disk" in *[!0-9a-f]*|'') bail hash_object_garbage ;; esac

    if is_secret "${path##*/}"; then
      secrets="${secrets}${path}"$'\n'
    else
      blobs="${blobs}${path}:${disk}"$'\n'
    fi

    # The outage signature, stated as content rather than as repo state: the
    # file being served differs from the file GitHub holds. git status would
    # call this dirty OR clean-but-unpushed depending on whether someone ran
    # commit, and check_git_drift grades those on a clock. This asks the
    # blunter question -- is production running config that GitHub does not
    # have? -- and names the files.
    if [ "$disk" != "${committed[$path]:-}" ]; then
      unpublished=$(( unpublished + 1 ))
      unpublished_list="${unpublished_list:+$unpublished_list,}${path##*/}"
    fi
  done
fi

emit generated        "$NOW"
emit deployed         "$deployed"
emit skipped          "$skipped"
emit unpublished      "$unpublished"
emit unpublished_list "$(printf %s "$unpublished_list" | cut -c1-300)"

while IFS= read -r line; do
  [ -n "$line" ] && emit blob "$line"
done <<< "$blobs"

while IFS= read -r line; do
  [ -n "$line" ] && emit secret "$line"
done <<< "$secrets"

emit end 1
