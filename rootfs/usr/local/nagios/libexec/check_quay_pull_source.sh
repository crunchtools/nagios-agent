#!/bin/bash
# Check that every systemd unit pulls crunchtools-owned images from quay.io,
# never ghcr.io. Quay is the canonical pull/run source for the fleet; GHCR is
# a mirror only (dual-push for redundancy + OCI auto-linking). Third-party
# images (e.g. ghcr.io/redhatinsights/...) are not ours to police and are
# ignored. Filed per RT #1468.
#
# Reads the host unit files through the read-only /etc/systemd/system bind
# mount that RT #1477 added to this container.
#
# It used to reach them with `nsenter -t 1 -m`, which needs CAP_SYS_ADMIN and
# root. NRPE runs plugins as nrpe, so the nsenter always failed -- and every
# failure mode (nsenter denied, PID 1 not enterable, glob matching nothing)
# landed in the same empty-string branch with stderr discarded, so the check
# reported OK without ever having looked. A check that reports OK when it did
# not run is worse than no check, because it occupies the slot where a working
# one would go. Hence the explicit UNKNOWN paths below (RT #1481).

set -uo pipefail

UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}

OK=0; CRITICAL=2; UNKNOWN=3

if [ ! -d "$UNIT_DIR" ]; then
    echo "QUAY PULL SOURCE UNKNOWN - $UNIT_DIR is not a directory; the bind mount is missing"
    exit $UNKNOWN
fi

if [ ! -r "$UNIT_DIR" ] || [ ! -x "$UNIT_DIR" ]; then
    echo "QUAY PULL SOURCE UNKNOWN - $UNIT_DIR is not readable by $(id -un 2>/dev/null || echo "uid $(id -u)")"
    exit $UNKNOWN
fi

shopt -s nullglob
candidates=("$UNIT_DIR"/*.service)
shopt -u nullglob

if [ ${#candidates[@]} -eq 0 ]; then
    echo "QUAY PULL SOURCE UNKNOWN - no .service files under $UNIT_DIR; the mount is present but empty"
    exit $UNKNOWN
fi

# Many entries here are enablement/alias symlinks into /usr/lib/systemd/system,
# which this container does not mount, so they dangle. That is expected and
# harmless -- units shipped in the image are not the ones anyone repoints at
# ghcr. Skip what we cannot read rather than letting grep exit 2 and turn the
# whole check UNKNOWN, but count the skips so a genuinely broken mount is still
# visible in the output.
units=(); skipped=0
for u in "${candidates[@]}"; do
    if [ -r "$u" ]; then units+=("$u"); else skipped=$((skipped + 1)); fi
done

if [ ${#units[@]} -eq 0 ]; then
    echo "QUAY PULL SOURCE UNKNOWN - all ${#candidates[@]} unit files under $UNIT_DIR are unreadable"
    exit $UNKNOWN
fi

# grep exits 0 on a match, 1 on no match, >1 on a real error. Only the last of
# those is a reason to stop trusting the result.
violations=$(grep -lE 'ghcr\.io/crunchtools/' "${units[@]}")
rc=$?

if [ "$rc" -gt 1 ]; then
    echo "QUAY PULL SOURCE UNKNOWN - grep over $UNIT_DIR exited $rc"
    exit $UNKNOWN
fi

if [ -n "$violations" ]; then
    count=$(printf '%s\n' "$violations" | wc -l)
    names=$(printf '%s\n' "$violations" | xargs -n1 basename | tr '\n' ' ')
    echo "QUAY PULL SOURCE CRITICAL - units pulling crunchtools images from ghcr.io instead of quay.io: ${names}| violations=${count};1;;0 scanned=${#units[@]} skipped=${skipped}"
    exit $CRITICAL
fi

echo "QUAY PULL SOURCE OK - all ${#units[@]} readable units pull crunchtools images from quay.io (${skipped} unreadable, normally /usr symlinks) | violations=0;1;;0 scanned=${#units[@]} skipped=${skipped}"
exit $OK
