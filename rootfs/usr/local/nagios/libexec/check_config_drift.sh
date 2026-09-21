#!/bin/bash
# check_config_drift.sh — does any deployed config file have a SECOND git home?
# (RT #1498)
#
# THE OUTAGE THIS ANSWERS TO. On 2026-09-20, exposing the Gemini connector
# meant editing the live proxy vhost. The host file was synced from git and
# four production vhosts vanished -- trentina, mcp-gw-personal, mcp-gw-work,
# mcp-pcloud -- taking josui's gateway to HTTP 403 until the backup came back.
# Scott's question afterwards was the right one: "I thought we have a Nagios
# check in place to catch config diffs like this?"
#
# We did, and it could not have. check_git_drift.sh asks whether /srv has
# drifted from ITS OWN origin. proxy.crunchtools.com.conf was tracked by TWO
# repos -- the deployed one in lotor.dc3.crunchtools.com-srv and a reference
# copy in crunchtools/proxy that was four vhosts behind -- and nothing compared
# them. The file was overwritten from the wrong home. No single-repo check can
# see that, because from inside either repo everything looks clean.
#
# WHAT THIS MEASURES. Three questions, three fixes, counted separately:
#
#   divergent   a deployed config file also lives in the project repo, and the
#               two copies differ. This is the loaded gun: whoever syncs from
#               the wrong home changes production. Delete the stale copy, or
#               reconcile it.
#   duplicate   the same, but the copies currently match. Not an alarm -- it is
#               the same file twice, and it stays harmless right up until one
#               side is edited. Perfdata only, so the trend is visible without
#               a permanently amber dashboard.
#   unpublished production is serving config that origin/master does not hold.
#               Measured as a content hash per file, not as repo state, so it
#               does not care whether someone ran commit. check_git_drift owns
#               the time-graded version of this; here it exists to qualify the
#               one above.
#
# THE LADDER, and why CRITICAL is narrow. hermes notifies on CRITICAL only
# (contacts.cfg, service_notification_options c), so WARNING is a dashboard
# colour that costs nothing and CRITICAL is a phone call. A rival copy sitting
# there is a latent hazard: WARNING. A file that is BOTH unpublished AND has a
# divergent rival is not latent -- that is the 2026-09-20 state exactly, the
# deployed file having been overwritten from a home that is not authoritative
# -- so it is CRITICAL.
#
# secret_exposed is its own CRITICAL and needs no divergence to qualify. A
# deployed .env, key or wp-config.php that ALSO lives in a public project repo
# is Constitution XVII, whether or not the two copies agree. It reads zero
# today and the point is to keep it there.
#
# WHAT IS NOT A SECOND HOME. Files under rootfs/ in a project repo are image
# content -- the default the image bakes in, which /srv is SUPPOSED to override
# per Constitution XIV. rt/rootfs/opt/rt6/etc/RT_SiteConfig.pm and the deployed
# RT_SiteConfig.pm are meant to differ, and calling that drift would be noise.
# check_plugin_drift.sh already guards image-vs-/srv where it matters.
# Containerfiles are skipped for the same reason: a build file is not config.
#
# HOW THE MATCH IS MADE. Basename alone is too loose -- postiz ships both
# rootfs/etc/temporal/config.yaml and .gemini/config.yaml, and matching the
# deployed config/temporal/config.yaml against the wrong one invents drift that
# does not exist. So candidates are scored by longest common trailing path
# suffix and the unique winner wins; a tie is reported as ambiguous rather than
# guessed at. That rule picks rootfs/etc/temporal/config.yaml, which is then
# correctly dropped as image content.
#
# ONE SERVICE CAN HAVE SEVERAL RIVALS, so config-sources.conf takes a
# comma-separated list. /srv/nagios.crunchtools.com/config/services/ is claimed
# by the nagios repo and by THIS one, which keeps reference copies of its own
# Nagios service definitions under deploy/nagios/. Candidates are scored across
# every rival at once and the single best counterpart wins, so a file claimed
# twice is reported once.
#
# HOW IT READS THE RIVALS. git clone --filter=blob:none --bare --depth 1, then
# ls-tree. Blob SHAs come out of the tree without downloading a single file, so
# the comparison is a string compare against the collector's hashes and no
# repository content is ever fetched. It also stays off the GitHub REST API,
# whose unauthenticated budget is 60 calls an hour against the ~30 repos this
# reads -- close enough to the ceiling that one retry storm would blind the
# check. git has no such budget and needs no token.
#
# HONESTY RULE (RT #1481, RT #1488, and check_registry_drift.sh). Never report
# OK for a comparison that did not happen. A repo that could not be read is
# counted as unchecked and named in the HEADLINE, not buried in the detail, and
# UNKNOWN wins when nothing drifted but something was unreadable.

set -uo pipefail

EXEC=${EXEC:-/usr/local/nagios/libexec/podman_exec.sh}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/config-drift-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent.crunchtools.com}
CONF=${CONFIG_DRIFT_CONF:-/etc/nagios/config-sources.conf}
ORG=${CONFIG_DRIFT_ORG:-crunchtools}
GIT_HOST=${CONFIG_DRIFT_GIT_HOST:-https://github.com}
# THE TIME BUDGET, measured rather than guessed. This runs on the HOST nrpe
# daemon, whose command_timeout is 15s (nrpe-host.cfg) -- a quarter of the 60s
# the container daemon allows, and deliberately so. Thirty-odd anonymous clones
# at 8-way ran 2s, 3s, 7s and 15s on four consecutive tries; the last one hit
# the ceiling exactly and came back as "NRPE: Command timed out" with no
# detail. At 16-way the same work is a consistent 2s, because the cost is
# round trips and not CPU.
#
# NET_TIMEOUT must stay UNDER command_timeout for the same reason. A per-clone
# bound longer than the daemon's is not a bound at all: the daemon kills the
# check first and the honesty machinery below -- which would have named the
# repo it could not read -- never gets to run.
NET_TIMEOUT=${CONFIG_DRIFT_TIMEOUT:-10}
JOBS=${CONFIG_DRIFT_JOBS:-16}

# Ratchet, per the lesson in factory-status.cfg and the note at the end of
# registry-drift.cfg: a check that is permanently amber is not honest, it is
# ignored. Ships at 0 -- every divergence found today is real work, listed by
# name -- and exists so the number can be pinned and walked down rather than
# tolerated silently.
MAX_DIVERGENT=${CONFIG_DRIFT_MAX_DIVERGENT:-0}

# Bare git against something it cannot read BLOCKS on a credential prompt
# rather than failing, and the check then goes UNKNOWN with no detail when NRPE
# gives up. Refuse the prompt, and bound every call with timeout regardless.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

[ -r "$CONF" ] || { echo "CONFIG DRIFT UNKNOWN - cannot read source map at ${CONF}"; exit $UNKNOWN; }

raw=$("$EXEC" "$CONTAINER" "$COLLECT" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || { echo "CONFIG DRIFT UNKNOWN - collector exec in $CONTAINER exited $rc"; exit $UNKNOWN; }

# Anchored extraction, not a line parse: podman_exec.sh strips the libpod
# stream framing byte-wise and a stray printable byte can survive it.
field() { printf '%s\n' "$raw" | grep -m1 -oE "CFGDRIFT $1=.*" | cut -d= -f2- ; }
fields() { printf '%s\n' "$raw" | grep -oE "CFGDRIFT $1=.*" | cut -d= -f2- ; }

[ -n "$(field end)" ] || { echo "CONFIG DRIFT UNKNOWN - collector output truncated or unrecognised"; exit $UNKNOWN; }

error=$(field error)
[ -n "$error" ] && { echo "CONFIG DRIFT UNKNOWN - collector reported: $error"; exit $UNKNOWN; }

deployed=$(field deployed)
unpublished=$(field unpublished)
unpublished_list=$(field unpublished_list)
for v in "$deployed" "$unpublished"; do
  case "$v" in ''|*[!0-9]*) echo "CONFIG DRIFT UNKNOWN - collector returned a non-numeric count"; exit $UNKNOWN ;; esac
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

[ "$corrupt" -eq 0 ] || { echo "CONFIG DRIFT UNKNOWN - ${corrupt} unparseable line(s) from the collector"; exit $UNKNOWN; }
[ "${#DISK[@]}" -gt 0 ] || { echo "CONFIG DRIFT UNKNOWN - collector published no config fingerprints"; exit $UNKNOWN; }

# Which service maps to which rival repo, and which services were never
# answered for. "none" is a deliberate answer; absence is not.
declare -A RIVAL=()
while read -r svc repo _; do
  case "$svc" in ''|\#*) continue ;; esac
  [ -n "${repo:-}" ] || continue
  # The repo field is a comma-separated list, because one service directory can
  # have more than one rival: everything under /srv/nagios.crunchtools.com/
  # config/services/ is claimed by the nagios repo AND by this one, which keeps
  # reference copies of its own Nagios service definitions in deploy/nagios/.
  #
  # Each name becomes a path under $WORK and an argument to git clone, so
  # anything that is not a GitHub repo name is a typo at best.
  # Validate the RAW field before splitting it. The split below is deliberately
  # unquoted so the commas become words, which also means pathname expansion --
  # a bare "*" in this column would otherwise expand to the names in the
  # working directory, every one of which then looks like a valid repo name and
  # gets cloned. Reject the field whole, then split what is left.
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
    '')     case " $unmapped " in *" $svc "*) : ;; *) unmapped="$unmapped $svc" ;; esac ;;
    none)   : ;;
    *)      for one in ${RIVAL[$svc]//,/ }; do NEEDED["$one"]=1; done ;;
  esac
done

# Shallow blobless clones, concurrently. Serially this is ~8s per repo against
# check_nrpe's ceiling; the lesson from check_registry_drift.sh is that a check
# which times out during a deploy -- precisely when someone is watching -- is
# worse than no check.
WORK=$(mktemp -d /tmp/config_drift.XXXXXX) || { echo "CONFIG DRIFT UNKNOWN - cannot create work directory"; exit $UNKNOWN; }
trap 'rm -rf "$WORK"' EXIT

fetch_tree() {
    local repo=$1
    if timeout "$NET_TIMEOUT" git clone -q --filter=blob:none --bare --depth 1 \
         "${GIT_HOST}/${ORG}/${repo}" "${WORK}/${repo}.git" 2>/dev/null \
       && git --git-dir="${WORK}/${repo}.git" ls-tree -r HEAD \
            --format='%(objectname) %(path)' > "${WORK}/${repo}.tree" 2>/dev/null \
       && [ -s "${WORK}/${repo}.tree" ]; then
        return 0
    fi
    rm -f "${WORK}/${repo}.tree"
    return 1
}
export -f fetch_tree
export GIT_HOST ORG WORK NET_TIMEOUT

if [ "${#NEEDED[@]}" -gt 0 ]; then
    printf '%s\n' "${!NEEDED[@]}" \
      | xargs -P "$JOBS" -I{} bash -c 'fetch_tree "$@"' _ {} >/dev/null 2>&1
fi

unreadable=""
for repo in "${!NEEDED[@]}"; do
    [ -s "${WORK}/${repo}.tree" ] || unreadable="$unreadable $repo"
done

# Longest common trailing path suffix, in components. The deployed
# config/temporal/config.yaml scores 2 against rootfs/etc/temporal/config.yaml
# and 1 against .gemini/config.yaml, which is how the right counterpart is
# found before anything is said about it.
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

divergent=0; duplicate=0; ambiguous=0; secret_exposed=0; critical_files=0
div_list=""; sec_list=""; amb_list=""

# One pass over every deployed config file. Secret-bearing paths carry no hash
# by design, so for them the question is presence, not equality.
for path in "${!DISK[@]}" "${!SECRET[@]}"; do
    svc=${path%%/*}
    base=${path##*/}
    repos=${RIVAL[$svc]:-}
    [ -n "$repos" ] && [ "$repos" != none ] || continue

    # A build file is not configuration; /srv keeps local Containerfiles for a
    # couple of services and comparing those to the repo's would flag forever.
    case "$base" in Containerfile|Dockerfile|.containerignore) continue ;; esac

    # Scored across every rival at once, not per rival, so the winner is the
    # single best counterpart in the org rather than one per repo -- otherwise
    # a file claimed by two repos would be reported twice.
    best=0; best_path=""; best_sha=""; best_repo=""; ties=0
    for repo in ${repos//,/ }; do
        [ -s "${WORK}/${repo}.tree" ] || continue
        while read -r rsha rpath; do
            [ "${rpath##*/}" = "$base" ] || continue
            score=$(suffix_score "$path" "$rpath")
            if [ "$score" -gt "$best" ]; then
                best=$score; best_path=$rpath; best_sha=$rsha; best_repo=$repo; ties=1
            elif [ "$score" -eq "$best" ] && [ "$best" -gt 0 ]; then
                ties=$(( ties + 1 ))
            fi
        done < "${WORK}/${repo}.tree"
    done

    [ "$best" -gt 0 ] || continue
    repo=$best_repo

    if [ "$ties" -gt 1 ]; then
        ambiguous=$(( ambiguous + 1 ))
        amb_list="$amb_list ${repo}/${base}"
        continue
    fi

    # Image content, not a second home for deployed config. See the header.
    case "$best_path" in rootfs/*) continue ;; esac

    if [ -n "${SECRET[$path]:-}" ]; then
        secret_exposed=$(( secret_exposed + 1 ))
        sec_list="$sec_list ${repo}/${best_path}"
        continue
    fi

    if [ "$best_sha" = "${DISK[$path]}" ]; then
        duplicate=$(( duplicate + 1 ))
    else
        divergent=$(( divergent + 1 ))
        div_list="$div_list ${repo}/${best_path}"
        # Deployed content that origin/master does not hold, in a file a rival
        # repo also claims. That is not a latent hazard, it is the state lotor
        # was in on 2026-09-20.
        case ",$unpublished_list," in *",$base,"*) critical_files=$(( critical_files + 1 )) ;; esac
    fi
done

# Workers and hash buckets both hand results back in whatever order they
# please, and without this the names shuffle between runs of an otherwise
# unchanged check.
sort_words() { printf '%s\n' $1 | sort | paste -sd' ' - | sed 's/^/ /'; }
[ -n "$div_list" ] && div_list=$(sort_words "$div_list")
[ -n "$sec_list" ] && sec_list=$(sort_words "$sec_list")
[ -n "$amb_list" ] && amb_list=$(sort_words "$amb_list")
[ -n "$unreadable" ] && unreadable=$(sort_words "$unreadable")
[ -n "$unmapped" ] && unmapped=$(sort_words "$unmapped")

n_unreadable=$(printf '%s' "$unreadable" | wc -w)
n_unmapped=$(printf '%s' "$unmapped" | wc -w)

perf="divergent=${divergent};$(( MAX_DIVERGENT + 1 ));;0"
perf="$perf duplicate=${duplicate};;;0"
perf="$perf unpublished=${unpublished};;;0"
perf="$perf secret_exposed=${secret_exposed};1;1;0"
perf="$perf ambiguous=${ambiguous};;;0"
perf="$perf unmapped=${n_unmapped};;;0"
perf="$perf unchecked=${n_unreadable};;;0"
perf="$perf deployed=${deployed};;;0"

detail=""
[ -n "$div_list" ] && detail="${detail}divergent:${div_list}. "
[ -n "$sec_list" ] && detail="${detail}secret-in-public-repo:${sec_list}. "
[ -n "$amb_list" ] && detail="${detail}ambiguous:${amb_list}. "
[ -n "$unreadable" ] && detail="${detail}unreadable:${unreadable}. "
[ -n "$unmapped" ] && detail="${detail}unmapped:${unmapped}. "
[ -n "$unpublished_list" ] && detail="${detail}unpublished:${unpublished_list}. "

drift=$(( divergent + secret_exposed ))

# UNKNOWN when we genuinely could not see. Not on any unreadable repo -- a
# single flaky clone would then bury real findings behind noise, the same way a
# check that never runs occupies the slot a working one would fill.
if [ "$n_unreadable" -gt 0 ] && [ "$drift" -eq 0 ]; then
    echo "CONFIG DRIFT UNKNOWN - ${n_unreadable} project repo(s) could not be read, nothing to compare against. ${detail}| $perf"
    exit $UNKNOWN
fi

if [ "$secret_exposed" -gt 0 ]; then
    echo "CONFIG DRIFT CRITICAL - ${secret_exposed} deployed secret file(s) also live in a project repo (Constitution XVII). ${detail}| $perf"
    exit $CRITICAL
fi

if [ "$critical_files" -gt 0 ]; then
    echo "CONFIG DRIFT CRITICAL - ${critical_files} deployed file(s) differ from origin/master AND from a rival git home - this is the 2026-09-20 state. ${detail}| $perf"
    exit $CRITICAL
fi

# Both of these belong in the HEADLINE, not the detail. A service nobody
# mapped and a repo nobody could read are the same kind of hole -- the part of
# the fleet this run did not actually look at -- and burying either one lets an
# OK be read as a complete picture, which is how 2026-09-20 stayed invisible.
blind=""
[ "$n_unreadable" -gt 0 ] && blind=", ${n_unreadable} repo(s) UNCHECKED"
[ "$n_unmapped" -gt 0 ] && blind="${blind}, ${n_unmapped} service(s) UNMAPPED"

if [ "$divergent" -le "$MAX_DIVERGENT" ]; then
    if [ "$divergent" -eq 0 ]; then
        echo "CONFIG DRIFT OK - ${deployed} deployed config file(s), none with a divergent second git home${blind} | $perf"
    else
        echo "CONFIG DRIFT OK - ${divergent} divergent, at or under the ratchet of ${MAX_DIVERGENT}${blind}. ${detail}| $perf"
    fi
    exit $OK
fi

echo "CONFIG DRIFT WARNING - ${divergent}/${deployed} deployed config file(s) have a divergent second git home${blind}. ${detail}| $perf"
exit $WARNING
