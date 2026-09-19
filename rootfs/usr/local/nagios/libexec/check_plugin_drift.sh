#!/bin/bash
# Check whether the plugins actually running differ from the ones released in
# the image.  RT #1490.
#
# WHY THIS EXISTS. The agent bind-mounts /srv over /usr/local/nagios/libexec,
# so /srv is what executes and the image copy is invisible at runtime. Nothing
# compared the two. The result (found 2026-09-19): the repo tracked 15 plugins
# while lotor ran 46 -- 31 in production with no source control, no review and
# no history, including both privilege-split helpers. Three of the tracked 15
# had also drifted, with the box ahead every time. An earlier stale chmod in
# the Containerfile shipped five plugins unrunnable for the same reason.
#
# Editing on the box is not the problem -- it is often the fastest way to fix
# an outage. Editing on the box and nobody ever finding out is the problem.
# This makes that visible within one check interval.
#
# WARNING, not CRITICAL, on purpose: drift is a process defect, not an outage,
# and hermes pages on CRITICAL only. This should nag, not wake anyone.
#
# Honesty rules, the whole point of the RT #1488 sweep: if the reference copy
# is missing or unreadable, say UNKNOWN. Never report "no drift" for a
# comparison that did not happen.

LIVE="${PLUGIN_DRIFT_LIVE:-/usr/local/nagios/libexec}"
RELEASED="${PLUGIN_DRIFT_RELEASED:-/usr/local/nagios/libexec-released}"

if [ ! -d "$RELEASED" ]; then
    echo "UNKNOWN - no released copy at ${RELEASED}; image predates RT #1490, rebuild the agent image to enable this check"
    exit 3
fi

if [ ! -d "$LIVE" ]; then
    echo "UNKNOWN - live plugin directory ${LIVE} is missing"
    exit 3
fi

# Positive proof we can actually read both sides. An empty listing here means
# we cannot see the files, which is not the same as the files matching.
live_count=$(find "$LIVE" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l)
rel_count=$(find "$RELEASED" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l)

if [ "$live_count" -eq 0 ] || [ "$rel_count" -eq 0 ]; then
    echo "UNKNOWN - cannot enumerate plugins (live=${live_count}, released=${rel_count}); check mounts and permissions"
    exit 3
fi

modified=""
only_live=""
only_released=""

for f in "$LIVE"/*.sh; do
    b=$(basename "$f")
    if [ ! -f "$RELEASED/$b" ]; then
        only_live="${only_live}${b} "
    elif ! cmp -s "$f" "$RELEASED/$b"; then
        modified="${modified}${b} "
    fi
done

for f in "$RELEASED"/*.sh; do
    b=$(basename "$f")
    [ -f "$LIVE/$b" ] || only_released="${only_released}${b} "
done

n_mod=$(printf '%s' "$modified" | wc -w)
n_live=$(printf '%s' "$only_live" | wc -w)
n_rel=$(printf '%s' "$only_released" | wc -w)
total=$(( n_mod + n_live + n_rel ))

PERFDATA="drifted=${total};1;;0; modified=${n_mod};;;0; unreleased=${n_live};;;0; missing=${n_rel};;;0;"

if [ "$total" -eq 0 ]; then
    echo "OK - all ${live_count} plugins match the released image | $PERFDATA"
    exit 0
fi

msg="PLUGIN DRIFT WARNING - ${total} differ from the released image:"
[ "$n_mod"  -gt 0 ] && msg="${msg} modified(${n_mod}): ${modified}"
[ "$n_live" -gt 0 ] && msg="${msg} running-but-never-released(${n_live}): ${only_live}"
[ "$n_rel"  -gt 0 ] && msg="${msg} released-but-not-running(${n_rel}): ${only_released}"

echo "${msg}| $PERFDATA"
exit 1
