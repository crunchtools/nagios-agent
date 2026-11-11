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
#   CRITICAL  an image has a fixable Critical CVE that is NOT in the accepted
#             baseline — a NEW fixable Critical. Page: pull in Josui, the move
#             may be take the service offline and hand-remediate. The fix is a
#             version BUMP (base/dep), not a same-commit rebuild — a rebuild does
#             not clear a pinned-version critical.
#   WARNING   an image has a fixable High CVE — bump within 6h.
#   OK        only unfixable findings, clean, or fixable Criticals that are ALL
#             in the baseline (known, accepted, already worked — surfaced in
#             perfdata as baselined_crit, never paged; a regression breaks out of
#             the baseline and pages).
#
# THE BASELINE. Paging on the standing backlog of known Criticals would teach the
# fleet to ignore the one signal that matters, so the check pages on CHANGE, not
# on presence. The baseline (CVE_BASELINE, default /etc/nagios/cve-baseline.conf)
# is the set of (image, CVE) pairs a human has seen and accepted — one
# `<image-ref> <cve-id>` per line, # comments allowed. A fixable Critical whose
# (image, cve) is in the baseline is known and does not page; anything else — a
# new CVE, a known CVE surfacing in a new image, or (fail-safe) a counted
# Critical with no finding line to attribute — is a regression and pages. An
# empty or missing baseline accepts nothing, so every fixable Critical pages:
# the file is SEEDED from the live findings at go-live, before paging is enabled.
#
# Image staleness (an image sitting weeks behind its errata) is NOT judged here:
# check_quay_staleness.sh already owns it. This check owns CVE severity.
#
# Usage: check_image_cve.sh [<fleet-list-file>]
#   The fleet list (same format as the scanner's fleet-images.conf: one image
#   ref per line, # comments) is the set of images that MUST appear in the file;
#   an absent one is a coverage gap, not a silent pass. Defaults to
#   $FLEET_LIST or /etc/nagios/cve-fleet-images.conf.

set -uo pipefail

# shellcheck source=collector-lib.sh
. "$(dirname "$0")/collector-lib.sh" || { echo "UNKNOWN - cannot load collector-lib.sh"; exit 3; }

STATUS=${STATUS:-$STATE_DIR/cve.status}
FLEET_LIST=${1:-${FLEET_LIST:-/etc/nagios/cve-fleet-images.conf}}
CVE_BASELINE=${CVE_BASELINE:-/etc/nagios/cve-baseline.conf}
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

# ── accepted baseline: (image, CVE) pairs a human has seen and accepted ───────
# Missing/empty is legal and means "nothing accepted" (every fixable Critical
# pages) — the fail-safe before the file is seeded at go-live. Keyed "<ref> <cve>".
declare -A base; base_total=0
if [ -r "$CVE_BASELINE" ]; then
    # Default IFS (whitespace) so "<ref> <cve>" splits into two fields; IFS= here
    # would drop the whole line into bref and leave bcve empty.
    while read -r bref bcve _; do
        [[ $bref =~ ^[A-Za-z0-9._:/@-]+$ ]] || continue
        [[ $bcve =~ ^[A-Za-z0-9._-]+$    ]] || continue   # CVE-…, GHSA-…
        base["$bref $bcve"]=1; base_total=$(( base_total + 1 ))
    done < <(grep -vE '^[[:space:]]*(#|$)' "$CVE_BASELINE")
fi

crit_imgs=(); warn_imgs=(); gap_imgs=(); base_hits=()
tot_fix_crit=0; tot_fix_high=0; tot_new_crit=0; tot_base_crit=0; ok_n=0

# Parse the scan ONCE. Item lines give per-image counts and result; finding lines
# give the per-CVE detail the baseline matches on. Both keyed by image ref; the
# item value becomes an array KEY, so validate it against the image-ref grammar
# first — an unvalidated subscript is a command-injection surface on some bash
# versions, the array-key analogue of the arithmetic validation above.
declare -A sresult sfcrit sfhigh fcves fdetail
while IFS= read -r line; do
    iref=$(cl_field item "$line")
    [[ $iref =~ ^[A-Za-z0-9._:/@-]+$ ]] || continue   # @ for digest-pinned refs
    if [[ $line == CVE\ finding\ item=* ]]; then
        # One fixable Critical: cve-findings emits only fixable Criticals, so
        # every finding line is one. Collect its CVE under the image, and keep a
        # short bump detail for the page text.
        fcve=$(cl_field cve "$line")
        [[ $fcve =~ ^[A-Za-z0-9._-]+$ ]] || continue
        fcves[$iref]="${fcves[$iref]:-} $fcve"
        pkg=$(cl_field pkg "$line"); inst=$(cl_field installed "$line"); fx=$(cl_field fix "$line")
        fdetail["$iref $fcve"]="${pkg:-?} ${inst:-?}->${fx:-?}"
    else
        sresult[$iref]=$(cl_field result "$line")
        sfcrit[$iref]=$(cl_field fix_crit "$line")
        sfhigh[$iref]=$(cl_field fix_high "$line")
    fi
done < <(grep -E '^CVE (item|finding item)=' <<<"$raw")

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

    # Split this image's fixable Criticals into new (not baselined) vs baselined,
    # using the per-CVE finding lines. Then reconcile against the count: any
    # fixable Critical the count claims but no finding line attributes is
    # UNACCOUNTED and treated as NEW (fail-safe — a Critical we cannot name to a
    # baseline entry must page, never be assumed accepted).
    new_cves=(); seen_findings=0
    for c in ${fcves[$ref]:-}; do
        seen_findings=$(( seen_findings + 1 ))
        if [ -n "${base["$ref $c"]+set}" ]; then
            tot_base_crit=$(( tot_base_crit + 1 ))
            base["$ref $c"]=hit
        else
            new_cves+=("$c")
        fi
    done
    unaccounted=$(( fc - seen_findings )); [ "$unaccounted" -lt 0 ] && unaccounted=0
    img_new=$(( ${#new_cves[@]} + unaccounted ))

    if [ "$img_new" -ge 1 ]; then
        # A NEW Critical outranks everything else on this image; it pages, and a
        # High on the same image is moot (CRITICAL already wins the verdict).
        tot_new_crit=$(( tot_new_crit + img_new ))
        label="$(basename "$ref")($img_new)"
        # Name the first new CVE's bump, so the page text is actionable at a glance.
        if [ "${#new_cves[@]}" -ge 1 ]; then
            d=${fdetail["$ref ${new_cves[0]}"]:-}
            label="$label ${new_cves[0]}${d:+ [$d]}"
        fi
        crit_imgs+=("$label")
    else
        # Not paging on this image. A baselined Critical and a fixable High are
        # independent: an image can carry both, so surface each — the High must
        # still WARN even when the image also has an accepted Critical. Only an
        # image with neither is clean.
        [ "$seen_findings" -ge 1 ] && base_hits+=("$(basename "$ref")($seen_findings)")
        [ "$fh" -ge 1 ] && warn_imgs+=("$(basename "$ref")($fh)")
        [ "$seen_findings" -eq 0 ] && [ "$fh" -eq 0 ] && ok_n=$(( ok_n + 1 ))
    fi
done

# Baseline entries that matched nothing this scan: harmless (a cleared CVE), but
# surfaced so the backlog can be pruned at go-live / by the enqueue step.
stale_base=0
for k in "${!base[@]}"; do [ "${base[$k]}" != hit ] && stale_base=$(( stale_base + 1 )); done

join() { local IFS=,; echo "$*"; }
perf="| new_crit=$tot_new_crit baselined_crit=$tot_base_crit fix_crit=$tot_fix_crit fix_high=$tot_fix_high images=${#expected[@]} crit_images=${#crit_imgs[@]} warn_images=${#warn_imgs[@]} gaps=${#gap_imgs[@]} baseline=$base_total stale_baseline=$stale_base db_age=${db_age}s scan_age=${file_age}s"
gaps_note=""; [ "${#gap_imgs[@]}" -gt 0 ] && gaps_note=" [not in scan: $(join "${gap_imgs[@]}")]"
base_note=""; [ "${#base_hits[@]}" -gt 0 ] && base_note=" [baselined: $(join "${base_hits[@]}")]"

# ── verdict: a real page outranks a coverage gap, which outranks a warning ────
if [ "${#crit_imgs[@]}" -gt 0 ]; then
    echo "CRITICAL - NEW fixable Critical CVE in ${#crit_imgs[@]} image(s): $(join "${crit_imgs[@]}")${base_note}${gaps_note} $perf"
    exit 2
elif [ "${#gap_imgs[@]}" -gt 0 ]; then
    echo "UNKNOWN - ${#gap_imgs[@]} listed image(s) absent from the scan or failed: $(join "${gap_imgs[@]}")${base_note} $perf"
    exit 3
elif [ "${#warn_imgs[@]}" -gt 0 ]; then
    echo "WARNING - fixable High CVE in ${#warn_imgs[@]} image(s): $(join "${warn_imgs[@]}")${base_note} $perf"
    exit 1
else
    echo "OK - no NEW fixable Critical/High CVEs across ${#expected[@]} fleet image(s)${base_note} $perf"
    exit 0
fi
