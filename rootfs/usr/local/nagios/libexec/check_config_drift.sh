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
# WHAT IS NOT A SECOND HOME: image content. A file the image BAKES IN is the
# default /srv is supposed to override per Constitution XIV, so the two are
# meant to differ and calling that drift is noise.
# rt/rootfs/opt/rt6/etc/RT_SiteConfig.pm and the deployed RT_SiteConfig.pm are
# the case in point. check_plugin_drift.sh already guards image-vs-/srv where
# it matters.
#
# The question is how to RECOGNISE image content, and "under rootfs/" is only
# an approximation of it. The repo itself gives the exact answer: whatever the
# Containerfile COPYs in. postiz keeps ecosystem.config.js at its repo root and
# syslog keeps config/rsyslog.conf, both COPYd into the image and both
# overridden from /srv at runtime -- exactly the rt pattern, and both reported
# as drift until this plugin learned to read the Containerfile. So the skip set
# is rootfs/ plus every COPY/ADD source, read from the repo. COPY --from=stage
# is ignored: that copies out of a build stage, not out of the repo.
#
# Containerfiles themselves are skipped too, for a different reason: a build
# file is not configuration.
#
# Neither is anything under docs/, tests/ or examples/. Those trees hold
# illustrations, fixtures and placeholders, which are written to differ from
# production and which nobody deploys from. trentina's
# docs/demo/profiles.yaml, a three-profile demo fixture, matched the deployed
# gateway profiles.yaml by name and turned the check amber the hour it was
# committed. A repo that keeps a real reference copy keeps it under deploy/,
# which is still compared.
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
#
# COLLECTOR (7.2.0). Both reads -- the fingerprint from
# nagios-agent.crunchtools.com and the clones -- and the matching above now
# happen in config-drift-repos-collect.sh, which writes config-drift.status;
# this plugin only judges that file, so a slow GitHub can no longer time the
# check out. When the file is missing or older than REFRESH (30m, under the
# 60m check_interval) the collector is started detached through
# `podman_exec.sh --detach` in nagios-agent-ctr.crunchtools.com and the
# previous run's file is judged. A repo whose last successful clone is older
# than STALE (3h) counts as unreadable and its findings are dropped, and the
# whole check is UNKNOWN "collector stale" when the file is missing or older
# than STALE. The ratchet and the CRITICAL ladder stay here.

set -uo pipefail

CONF=${CONFIG_DRIFT_CONF:-/etc/nagios/config-sources.conf}

# Ratchet, per the lesson in factory-status.cfg and the note at the end of
# registry-drift.cfg: a check that is permanently amber is not honest, it is
# ignored. Ships at 0 -- every divergence found today is real work, listed by
# name -- and exists so the number can be pinned and walked down rather than
# tolerated silently.
MAX_DIVERGENT=${CONFIG_DRIFT_MAX_DIVERGENT:-0}

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "CONFIG DRIFT UNKNOWN - cannot load collector-lib.sh"; exit $UNKNOWN; }
STATUS=${STATUS:-$STATE_DIR/config-drift.status}
COLLECT=${COLLECT:-/usr/local/nagios/libexec/config-drift-repos-collect.sh}
CONTAINER=${CONTAINER:-nagios-agent-ctr.crunchtools.com}
REFRESH=${REFRESH:-1800}
STALE=${STALE:-10800}

cl_open CFGDRIFT "CONFIG DRIFT"
head=$(grep -m1 '^CFGDRIFT generated=' <<< "$CL_RAW")
error=$(cl_field error "$head")
case "$error" in
    '') ;;
    conf_unreadable) echo "CONFIG DRIFT UNKNOWN - cannot read source map at ${CONF}"; exit $UNKNOWN ;;
    *) echo "CONFIG DRIFT UNKNOWN - collector reported: ${error//_/ }"; exit $UNKNOWN ;;
esac

deployed=$(cl_field deployed "$head")
unpublished=$(cl_field unpublished "$head")
for v in "$deployed" "$unpublished"; do
  case "$v" in ''|*[!0-9]*) echo "CONFIG DRIFT UNKNOWN - collector returned a non-numeric count"; exit $UNKNOWN ;; esac
done
unpublished_list=$(grep -m1 '^CFGDRIFT unpublished_list=' <<< "$CL_RAW" | cut -d= -f2-)

# A repo whose last good clone is older than STALE is not judged.
now=$(date +%s)
unreadable=""
declare -A FRESH=()
while IFS= read -r line; do
    repo=$(cl_field repo "$line"); seen=$(cl_field seen "$line")
    if [ "${seen:-0}" -gt 0 ] && [ $(( now - seen )) -lt "$STALE" ]; then
        FRESH["$repo"]=1
    else
        unreadable="$unreadable $repo"
    fi
done < <(grep '^CFGDRIFT repo=' <<< "$CL_RAW")

unmapped=""
while IFS= read -r line; do
    unmapped="$unmapped ${line#CFGDRIFT unmapped=}"
done < <(grep '^CFGDRIFT unmapped=' <<< "$CL_RAW")

divergent=0; duplicate=0; ambiguous=0; secret_exposed=0; critical_files=0
div_list=""; sec_list=""; amb_list=""
file_re='(^| )file=(.*)$'

while IFS= read -r line; do
    repo=$(cl_field repo "$line")
    [ -n "${FRESH[$repo]:-}" ] || continue
    [[ $line =~ $file_re ]] || continue
    file=${BASH_REMATCH[2]}
    base=$(cl_field base "$line")
    case "$(cl_field kind "$line")" in
        AMBIGUOUS) ambiguous=$(( ambiguous + 1 )); amb_list="$amb_list $file" ;;
        SECRET)    secret_exposed=$(( secret_exposed + 1 )); sec_list="$sec_list $file" ;;
        DUPLICATE) duplicate=$(( duplicate + 1 )) ;;
        DIVERGENT)
            divergent=$(( divergent + 1 )); div_list="$div_list $file"
            # Deployed content that origin/master does not hold, in a file a
            # rival repo also claims. That is not a latent hazard, it is the
            # state lotor was in on 2026-09-20.
            case ",$unpublished_list," in *",$base,"*) critical_files=$(( critical_files + 1 )) ;; esac ;;
    esac
done < <(grep '^CFGDRIFT item ' <<< "$CL_RAW")

# The collector sorts its lines; strip the leading space the lists build with.
[ -n "$div_list" ] && div_list=" ${div_list# }"
[ -n "$sec_list" ] && sec_list=" ${sec_list# }"
[ -n "$amb_list" ] && amb_list=" ${amb_list# }"

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
perf="$perf collected_age=${CL_AGE}s;;${STALE}"

detail=""
[ -n "$div_list" ] && detail="${detail}divergent:${div_list}. "
[ -n "$sec_list" ] && detail="${detail}secret-in-public-repo:${sec_list}. "
[ -n "$amb_list" ] && detail="${detail}ambiguous:${amb_list}. "
[ -n "$unreadable" ] && detail="${detail}unreadable:${unreadable}. "
[ -n "$unmapped" ] && detail="${detail}unmapped:${unmapped}. "
[ -n "$unpublished_list" ] && detail="${detail}unpublished:${unpublished_list}. "
[ -n "$CL_KICKED" ] && detail="${detail}${CL_KICKED# }. "

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
