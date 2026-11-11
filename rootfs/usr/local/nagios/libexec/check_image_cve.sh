#!/bin/bash
# check_image_cve.sh — route the fleet CVE scan (RT #1551).
#
# Reads cve.status, written by the grype oneshot (quay.io/crunchtools/grype) on
# gloval every 6h. This check NEVER scans and never starts the collector: the
# scan is heavy and Kagetora-fired, so the check only judges the file the scan
# left. One service for the whole fleet; the output names the offending images.
#
# Verdict, worst-first:
#   UNKNOWN   the file is missing, truncated, or older than FILE_STALE; or the
#             scanner's own vulnerability DB is older than DB_STALE (a stale DB
#             is the hermes failure in the scanner — db_built, not scan time,
#             decides this); or a listed image is absent from the file or failed
#             to scan AND nothing is CRITICAL (a coverage gap outranks a mere
#             warning, but never masks a real page).
#   CRITICAL  an image has a FIXABLE Critical CVE — page, and rebuild.
#   WARNING   an image has a FIXABLE High CVE — rebuild within 6h.
#   OK        only unfixable findings, or clean.
#
# Image staleness (an image sitting weeks behind its errata) is NOT judged here:
# check_quay_staleness.sh already owns it. This check owns CVE severity.
#
# Usage: check_image_cve.sh [<fleet-list-file>]
#   The fleet list (same format as the scanner's fleet-images.conf: one image
#   ref per line, # comments) is the set of images that MUST appear in the file;
#   an absent one is a coverage gap, not a silent pass. Defaults to
#   $FLEET_LIST or /etc/nagios/fleet-images.conf.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "UNKNOWN - cannot load collector-lib.sh"; exit 3; }

STATUS=${STATUS:-$STATE_DIR/cve.status}
FLEET_LIST=${1:-${FLEET_LIST:-/etc/nagios/cve-fleet-images.conf}}
FILE_STALE=${FILE_STALE:-32400}     # 9h: one missed 6h run plus slack
DB_STALE=${DB_STALE:-172800}        # 48h

now=$(date +%s)

# ── file present, whole, and fresh ────────────────────────────────────────────
[ -r "$STATUS" ] || { echo "UNKNOWN - no scan: $STATUS missing"; exit 3; }
raw=$(cat "$STATUS")
grep -qx "CVE end=1" <<<"$raw" || { echo "UNKNOWN - scan file $STATUS is truncated"; exit 3; }

header=$(grep -m1 '^CVE generated=' <<<"$raw")
generated=$(cl_field generated "$header")
db_built=$(cl_field db_built "$header")
# Validate before any arithmetic: a non-numeric value inside $(( )) is a
# code-execution vector — bash evaluates array subscripts there, and a subscript
# can carry a command substitution. cve.status is written by a trusted root
# oneshot, but a status plugin must not trust a file's shape; a malformed field
# is UNKNOWN, never a shell. fix_crit/fix_high are validated the same way below.
[[ $generated =~ ^[0-9]+$ ]] || { echo "UNKNOWN - $STATUS: malformed generated field"; exit 3; }
[[ $db_built  =~ ^[0-9]+$ ]] || { echo "UNKNOWN - $STATUS: malformed db_built field"; exit 3; }
# Force base 10: a digit string with a leading zero (08, 09) is octal in bash
# arithmetic and errors ("value too great for base 8") instead of computing.
generated=$(( 10#$generated )); db_built=$(( 10#$db_built ))

file_age=$(( now - generated ))
if [ "$generated" -eq 0 ] || [ "$file_age" -ge "$FILE_STALE" ]; then
    echo "UNKNOWN - scan is stale: last run $(cl_hm "$file_age") ago [max $(cl_hm "$FILE_STALE")] | scan_age=${file_age}s;;${FILE_STALE}"
    exit 3
fi

db_age=$(( now - db_built ))
if [ "$db_built" -eq 0 ] || [ "$db_age" -ge "$DB_STALE" ]; then
    echo "UNKNOWN - scanner vulnerability DB is stale: built $(cl_hm "$db_age") ago [max $(cl_hm "$DB_STALE")]; findings unreliable | db_age=${db_age}s;;${DB_STALE}"
    exit 3
fi

# ── expected image set ────────────────────────────────────────────────────────
[ -r "$FLEET_LIST" ] || { echo "UNKNOWN - fleet list $FLEET_LIST not readable"; exit 3; }
mapfile -t expected < <(grep -vE '^[[:space:]]*(#|$)' "$FLEET_LIST" | awk '{print $1}')
[ "${#expected[@]}" -gt 0 ] || { echo "UNKNOWN - fleet list $FLEET_LIST is empty"; exit 3; }

crit_imgs=(); warn_imgs=(); gap_imgs=()
tot_fix_crit=0; tot_fix_high=0; ok_n=0

# Parse every scan item line ONCE into associative arrays keyed by image ref,
# then look each expected image up in O(1) — O(N) overall, not O(N^2). cl_field
# reads the item= value up to the next space, so the key is the exact ref.
declare -A sresult sfcrit sfhigh
while IFS= read -r line; do
    iref=$(cl_field item "$line")
    # The item value becomes a map KEY; validate it against the image-ref grammar
    # first. An unvalidated array subscript is a command-injection surface on some
    # bash versions — the array-key analogue of the arithmetic validation above.
    [[ $iref =~ ^[A-Za-z0-9._:/@-]+$ ]] || continue   # @ for digest-pinned refs
    sresult[$iref]=$(cl_field result "$line")
    sfcrit[$iref]=$(cl_field fix_crit "$line")
    sfhigh[$iref]=$(cl_field fix_high "$line")
done < <(grep '^CVE item=' <<<"$raw")

for img in "${expected[@]}"; do
    ref=$img; [[ $ref == *:* ]] || ref="$ref:latest"
    if [ -z "${sresult[$ref]+set}" ] || [ "${sresult[$ref]}" != "ok" ]; then
        gap_imgs+=("$ref"); continue
    fi
    fc=${sfcrit[$ref]}; fh=${sfhigh[$ref]}
    # Validate before arithmetic (see note above), and force base 10 so a value
    # like 08 is eight, not an octal error.
    [[ $fc =~ ^[0-9]+$ ]] && fc=$(( 10#$fc )) || fc=0
    [[ $fh =~ ^[0-9]+$ ]] && fh=$(( 10#$fh )) || fh=0
    tot_fix_crit=$(( tot_fix_crit + fc )); tot_fix_high=$(( tot_fix_high + fh ))
    if   [ "$fc" -ge 1 ]; then crit_imgs+=("$(basename "$ref")($fc)")
    elif [ "$fh" -ge 1 ]; then warn_imgs+=("$(basename "$ref")($fh)")
    else ok_n=$(( ok_n + 1 )); fi
done

join() { local IFS=,; echo "$*"; }
perf="| fix_crit=$tot_fix_crit fix_high=$tot_fix_high images=${#expected[@]} crit_images=${#crit_imgs[@]} warn_images=${#warn_imgs[@]} gaps=${#gap_imgs[@]} db_age=${db_age}s scan_age=${file_age}s"
gaps_note=""; [ "${#gap_imgs[@]}" -gt 0 ] && gaps_note=" [not in scan: $(join "${gap_imgs[@]}")]"

# ── verdict: a real page outranks a coverage gap, which outranks a warning ────
if [ "${#crit_imgs[@]}" -gt 0 ]; then
    echo "CRITICAL - fixable Critical CVE in ${#crit_imgs[@]} image(s): $(join "${crit_imgs[@]}")${gaps_note} $perf"
    exit 2
elif [ "${#gap_imgs[@]}" -gt 0 ]; then
    echo "UNKNOWN - ${#gap_imgs[@]} listed image(s) absent from the scan or failed: $(join "${gap_imgs[@]}") $perf"
    exit 3
elif [ "${#warn_imgs[@]}" -gt 0 ]; then
    echo "WARNING - fixable High CVE in ${#warn_imgs[@]} image(s): $(join "${warn_imgs[@]}") $perf"
    exit 1
else
    echo "OK - no fixable Critical/High CVEs across ${#expected[@]} fleet image(s) $perf"
    exit 0
fi
