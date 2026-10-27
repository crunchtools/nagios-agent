#!/bin/bash
# Offline tests for the exec-free container plugins (RT #1513), the
# collector + status-file checks (backups, Cloudflare, Quay, registry drift,
# Google OAuth) and the Cloudflare component filter. curl, rclone and
# podman_exec.sh are stubbed, so this runs anywhere with bash and GNU grep -P,
# no Podman socket needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBEXEC="$HERE/../rootfs/usr/local/nagios/libexec"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT
PASS=0
FAIL=0

# curl stub: socket calls return STUB_SOCK (exit STUB_SOCK_RC); direct calls
# return STUB_DIRECT (exit STUB_DIRECT_RC).
cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    if [ "$a" = "--unix-socket" ]; then printf '%s' "${STUB_SOCK:-}"; exit "${STUB_SOCK_RC:-0}"; fi
done
printf '%s' "${STUB_DIRECT:-}"
exit "${STUB_DIRECT_RC:-0}"
STUB
cat > "$STUBS/podman_exec.sh" <<'STUB'
#!/bin/bash
touch "$STUB_EXEC_MARK"
printf '%s' "${STUB_EXEC:-}"
exit "${STUB_EXEC_RC:-0}"
STUB
chmod +x "$STUBS/curl" "$STUBS/podman_exec.sh"
export PATH="$STUBS:$PATH" PODMAN_EXEC="$STUBS/podman_exec.sh" STUB_EXEC_MARK="$STUBS/exec-ran"

# expect <desc> <rc> <output-regex> <exec: yes|no|any> -- <plugin> <args...>
expect() {
    local desc="$1" want_rc="$2" want_out="$3" want_exec="$4"
    shift 5
    rm -f "$STUB_EXEC_MARK"
    local out rc ran=no
    out=$("$@" 2>&1); rc=$?
    [ -e "$STUB_EXEC_MARK" ] && ran=yes
    if [ "$rc" = "$want_rc" ] && [[ "$out" =~ $want_out ]] && { [ "$want_exec" = any ] || [ "$ran" = "$want_exec" ]; }; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (rc=$rc exec=$ran) $out"; FAIL=$((FAIL + 1))
    fi
}

ok_if() { # <desc> <command...>: PASS when the command succeeds
    local d=$1; shift
    if "$@"; then echo "  PASS: $d"; PASS=$((PASS + 1)); else echo "  FAIL: $d"; FAIL=$((FAIL + 1)); fi
}

PC="$LIBEXEC/check_container_process_count.sh"
HTTP="$LIBEXEC/check_container_httpd_internal.sh"

echo "=== check_container_process_count ==="
TOP='{"Processes":[["1","php-fpm: master process"],["7","php-fpm: pool www"],["9","worker --expr=foo] target-worker"],["11","sh -c \"quoted arg\" C:\\dir"]],"Titles":["PID","COMMAND"]}'
STUB_SOCK="$TOP" expect "counts matching args" 0 "OK .*2 processes" any -- "$PC" ctr php-fpm 1 1 X
STUB_SOCK="$TOP" expect "] inside args does not cut the row" 0 "OK .*1 processes" any -- "$PC" ctr target-worker 1 1 X
STUB_SOCK="$TOP" expect "escaped quotes are decoded" 0 "OK .*1 processes" any -- "$PC" ctr 'sh -c "quoted' 1 1 X
STUB_SOCK="$TOP" expect "escaped backslash is decoded" 0 "OK .*1 processes" any -- "$PC" ctr 'C:\\dir' 1 1 X
STUB_SOCK="$TOP" expect "Titles row is not counted" 2 "CRITICAL .*0 processes" any -- "$PC" ctr COMMAND 1 1 X
STUB_SOCK="$TOP" expect "below warn threshold" 1 "WARNING .*2 processes" any -- "$PC" ctr php-fpm 3 1 X
STUB_SOCK='{"cause":"no such container","message":"no container with name or ID \"x\" found","response":404}' \
    expect "API error is UNKNOWN, not 0" 3 "UNKNOWN .*no container" any -- "$PC" x php-fpm 1 1 X
STUB_SOCK='{"Processes":[],"Titles":["PID","COMMAND"]}' expect "empty table is UNKNOWN" 3 "UNKNOWN .*no process rows" any -- "$PC" ctr php-fpm 1 1 X
STUB_SOCK_RC=28 expect "socket timeout is UNKNOWN" 3 "UNKNOWN .*curl exit 28" any -- "$PC" ctr php-fpm 1 1 X
expect "bad container name rejected" 3 "UNKNOWN - invalid container" any -- "$PC" '../../x#' php-fpm 1 1 X

echo "=== check_container_httpd_internal ==="
IPJSON='{"NetworkSettings":{"IPAddress":"","Networks":{"podman":{"IPAddress":"10.88.0.7"}}}}'
STUB_SOCK="$IPJSON" STUB_DIRECT="200 0.01" expect "direct success skips exec" 0 "OK .*200" no -- "$HTTP" ctr 80 /
STUB_SOCK="$IPJSON" STUB_DIRECT="000 0.00" STUB_DIRECT_RC=7 STUB_EXEC="200 0.01" \
    expect "refused falls back to exec" 0 "OK .*200" yes -- "$HTTP" ctr 5000 /
STUB_SOCK="$IPJSON" STUB_DIRECT="000 10.00" STUB_DIRECT_RC=28 \
    expect "timeout does not fall back" 2 "CRITICAL .*no HTTP response" no -- "$HTTP" ctr 80 /
STUB_SOCK='{"NetworkSettings":{"IPAddress":""}}' STUB_EXEC="301 0.01" \
    expect "no bridge IP uses exec" 0 "OK .*301" yes -- "$HTTP" ctr 80 /
STUB_SOCK='{"NetworkSettings":{"IPAddress":""}}' STUB_EXEC_RC=7 \
    expect "exec fallback failure is CRITICAL" 2 "CRITICAL .*unreachable" yes -- "$HTTP" ctr 80 /
STUB_SOCK="$IPJSON" STUB_DIRECT="500 0.01" expect "unexpected code is CRITICAL" 2 "CRITICAL .*unexpected 500" no -- "$HTTP" ctr 80 /
expect "port with @ rejected" 3 "UNKNOWN - invalid port" no -- "$HTTP" ctr '80@1.1.1.1' /
expect "port out of range rejected" 3 "UNKNOWN - invalid port" no -- "$HTTP" ctr 70000 /
expect "path without leading / rejected" 3 "UNKNOWN - invalid path" no -- "$HTTP" ctr 80 '@evil/'
expect "bad container name rejected" 3 "UNKNOWN - invalid container" no -- "$HTTP" '../../containers/json#' 80 /

echo "=== podman_exec (exec stream decoding) ==="
# A second curl stub that plays the three Podman API calls: create returns an
# exec id, start writes $STUB_FRAMES to the -o file, inspect returns
# $STUB_INSPECT. Frames are built with printf so the header bytes are exact.
XSTUBS="$(mktemp -d)"
cat > "$XSTUBS/curl" <<'STUB'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        http://*) url="$1" ;;
    esac
    shift
done
case "$url" in
    */start) cat "$STUB_FRAMES" > "$out" ;;
    */exec/*/json) printf '%s' "$STUB_INSPECT" ;;
    */exec) printf '%s' "${STUB_CREATE-{\"Id\":\"abc123\"\}}" ;;
esac
STUB
chmod +x "$XSTUBS/curl"
PX="$LIBEXEC/podman_exec.sh"
FRAMES="$XSTUBS/frames"

# frame <stream-id> <payload-file>: header (id, 3 zero bytes, big-endian length) + payload
frame() {
    local size; size=$(stat -c %s "$2")
    printf "$(printf '\\%03o\\000\\000\\000\\%03o\\%03o\\%03o\\%03o' "$1" \
        $((size >> 24 & 255)) $((size >> 16 & 255)) $((size >> 8 & 255)) $((size & 255)))"
    cat "$2"
}
px() { PATH="$XSTUBS:$PATH" STUB_FRAMES="$FRAMES" "$PX" "$@"; }

# 2609 bytes: the length field is 0x0A31, a newline and "1". The old printable
# filter left both in front of the output.
head -c 2609 /dev/zero | tr '\0' x > "$XSTUBS/big"
frame 1 "$XSTUBS/big" > "$FRAMES"
OUT=$(STUB_INSPECT='{"ExitCode":0}' px ctr true); RC=$?
if [ "$RC" = 0 ] && [ "${#OUT}" = 2609 ] && [ -z "$(printf '%s' "$OUT" | tr -d x)" ]; then
    echo "  PASS: printable length bytes do not leak into output"; PASS=$((PASS + 1))
else
    echo "  FAIL: printable length bytes leak (rc=$RC len=${#OUT})"; FAIL=$((FAIL + 1))
fi

printf 'Threads_conn' > "$XSTUBS/a"; printf 'ected\t7\n' > "$XSTUBS/b"; printf 'warn\n' > "$XSTUBS/e"
{ frame 1 "$XSTUBS/a"; frame 1 "$XSTUBS/b"; frame 2 "$XSTUBS/e"; } > "$FRAMES"
STUB_INSPECT='{"ExitCode":0}' expect "line split across frames is rejoined, stderr kept" 0 $'^Threads_connected\t7\nwarn$' any -- px ctr true

frame 1 "$XSTUBS/a" > "$FRAMES"
STUB_INSPECT='{"ExitCode":7}' expect "command exit code is passed through" 7 "Threads_conn" any -- px ctr true
STUB_INSPECT='' expect "missing exit code is an error, not 0" 3 "EXEC_ERROR: no exit code" any -- px ctr true
: > "$FRAMES"
STUB_INSPECT='{"ExitCode":0}' expect "empty stream gives empty output" 0 "^$" any -- px ctr true
STUB_CREATE='{"cause":"no such container"}' STUB_INSPECT='' expect "exec that cannot be created exits 3" 3 "EXEC_ERROR: Cannot create exec" any -- px ctr true
rm -rf "$XSTUBS"

echo "=== backup freshness: collector, status file, kick ==="
# Both backup checks only read the status file backup-freshness-collect.sh
# writes; the collector is driven here directly with a stubbed rclone. The
# plugins' detached kick goes through the podman_exec stub, whose mark file
# says whether a collector run was started and with which arguments.
COL="$LIBEXEC/backup-freshness-collect.sh"
BSTATE="$(mktemp -d)"
KSTUBS="$(mktemp -d)"
cat > "$KSTUBS/exec" <<'STUB'
#!/bin/bash
echo "$*" > "$STUB_EXEC_MARK"
exit "${STUB_KICK_RC:-0}"
STUB
chmod +x "$KSTUBS/exec"
export STATE_DIR="$BSTATE"
# check <plugin>: run a backup plugin against $BSTATE, kicking through the stub
chk() { EXEC="$KSTUBS/exec" COLLECT=/collector "$@"; }
age_file() { # <file> <secs>: rewrite generated= (and seen=) as <secs> ago
    local t=$(( $(date +%s) - $2 ))
    sed -i -E "s/generated=[0-9]+/generated=$t/; s/seen=[0-9]+/seen=$t/g" "$1"
}
kicked() { # <desc> <yes|no>
    local ran=no; [ -e "$STUB_EXEC_MARK" ] && ran=yes
    if [ "$ran" = "$2" ]; then echo "  PASS: $1"; PASS=$((PASS + 1))
    else echo "  FAIL: $1 (kicked=$ran)"; FAIL=$((FAIL + 1)); fi
}

echo "=== check_personal_backup_freshness ==="
PB="$LIBEXEC/check_personal_backup_freshness.sh"
PSTAT="$BSTATE/personal-backup-freshness.status"
RSTUBS="$(mktemp -d)"
cat > "$RSTUBS/rclone" <<'STUB'
#!/bin/bash
[ -n "${STUB_SLOW:-}" ] && exec sleep 30
printf '%s' "${STUB_MARKERS:-}"
exit "${STUB_RCLONE_RC:-0}"
STUB
chmod +x "$RSTUBS/rclone"
pcol() { RCLONE="$RSTUBS/rclone" CONF=/dev/null "$COL" personal; }
pb() { rm -f "$PSTAT"; pcol; chk "$PB"; }
# markers <weekly age days> <monthly age days> [rclone exit]: all twelve markers
markers() {
    local now; now=$(date +%s)
    for d in Documents Downloads Autosync Projects; do
        echo "Files|$d|Weekly-1|0|$((now - $1 * 86400))|${3:-0}"
        echo "Files|$d|Monthly-1|0|$((now - $2 * 86400))|0"
        echo "Files|$d|Monthly-2|0|$((now - $2 * 86400))|0"
    done
}
STUB_MARKERS="$(markers 2 40)" expect "all twelve fresh" 0 "OK - Weekly-1 4/4 fresh \\(worst 2d\\); Monthly-1 4/4 .*problems=0" no -- pb
STUB_MARKERS="$(markers 10 40)" expect "weekly past warn" 1 "WARNING .*Documents/Weekly-1: aging 10d" any -- pb
STUB_MARKERS="$(markers 16 40)" expect "weekly past crit" 2 "CRITICAL .*Projects/Weekly-1: STALE 16d" any -- pb
STUB_MARKERS="$(markers 2 69)" expect "monthly just inside warn" 0 "OK .*Monthly-2 4/4" any -- pb
STUB_MARKERS="$(markers 2 100)" expect "monthly past crit" 2 "CRITICAL .*Autosync/Monthly-1: STALE 100d" any -- pb
STUB_MARKERS="$(markers 0 40 3)" expect "fresh but failed run is CRITICAL" 2 "CRITICAL .*last run FAILED \\(rclone exit 3\\), 0d ago" any -- pb
STUB_MARKERS="$(markers 2 40 | grep -v 'Downloads|Monthly-2')" \
    expect "one missing marker" 2 "CRITICAL .*Monthly-2 3/4 .*Downloads/Monthly-2: MISSING marker" any -- pb
STUB_MARKERS="$(markers 2 40 | sed 's/^Files|Autosync|Weekly-1|.*/Files|Autosync|Weekly-1|oops/')" \
    expect "garbled marker" 2 "CRITICAL .*Autosync/Weekly-1: unreadable marker" any -- pb
STUB_MARKERS="" STUB_RCLONE_RC=3 expect "no markers at all" 2 "CRITICAL - cannot read markers .*rclone exit 3" any -- pb
STUB_MARKERS="" expect "empty folder" 2 "CRITICAL - cannot read markers .*rclone exit 0" any -- pb
STUB_MARKERS="$(markers 2 40)" STUB_RCLONE_RC=1 expect "failed read is not judged on partial output" 2 "CRITICAL - cannot read markers .*rclone exit 1" any -- pb
STUB_MARKERS="" STUB_RCLONE_RC=124 expect "first-ever read timing out is UNKNOWN" 3 "UNKNOWN - collector timed out" any -- pb
rm -f "$PSTAT"; STUB_MARKERS="$(markers 2 40)" pcol
STUB_MARKERS="" STUB_RCLONE_RC=124 pcol
expect "timeout keeps the last markers" 0 "OK - Weekly-1 4/4 fresh" no -- chk "$PB"
grep -q 'lastfail=timeout' "$PSTAT" && { echo "  PASS: timeout is recorded as lastfail"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: no lastfail=timeout in status"; FAIL=$((FAIL + 1)); }
rm -f "$PSTAT"; STUB_MARKERS="$(markers 2 40)" pcol; age_file "$PSTAT" 1500
expect "status past REFRESH is still judged" 0 "OK - Weekly-1 4/4" any -- chk "$PB"
kicked "status past REFRESH starts the collector" yes
age_file "$PSTAT" 7300
expect "status older than 2h is UNKNOWN collector stale" 3 "^PERSONAL BACKUPS UNKNOWN - collector stale: last collection 2h" yes -- chk "$PB"
rm -f "$PSTAT"
expect "missing status file is UNKNOWN and starts the collector" 3 "^PERSONAL BACKUPS UNKNOWN - collector stale: no status file .*collector started" yes -- chk "$PB"
grep -q -- '--detach nagios-agent.crunchtools.com /collector personal' "$STUB_EXEC_MARK" \
    && { echo "  PASS: kick is a detached exec of the personal collector"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: kick args: $(cat "$STUB_EXEC_MARK")"; FAIL=$((FAIL + 1)); }
STUB_KICK_RC=3 expect "failed kick is reported" 3 "collector could not be started" yes -- chk "$PB"
RCLONE=/nonexistent CONF=/dev/null expect "collector without rclone exits 3, writes nothing" 3 "not mounted" any -- "$COL" personal
[ -e "$PSTAT" ] && { echo "  FAIL: collector wrote a status without rclone"; FAIL=$((FAIL + 1)); }
expect "collector rejects an unknown mode" 3 "usage" any -- "$COL" bogus
rm -rf "$RSTUBS"

echo "=== check_backup_freshness ==="
BF="$LIBEXEC/check_backup_freshness.sh"
BSTAT="$BSTATE/backup-freshness.status"
BSTUBS="$(mktemp -d)"
# rclone stub keyed on the listed path (its last argument): STUB_SLOW hangs,
# STUB_FAIL exits STUB_FAIL_RC, STUB_GONE exits 3 like a missing directory;
# everything else lists one file STUB_AGE days old and STUB_SIZE bytes. Each
# call appends the path to $STUB_CALLS so retries can be counted.
cat > "$BSTUBS/rclone" <<'STUB'
#!/bin/bash
p="${!#}"
echo "$p" >> "$STUB_CALLS"
hit() { [ -n "$1" ] && [[ "$p" == *"$1"* ]]; }
hit "${STUB_SLOW:-}" && exec sleep 30
hit "${STUB_FAIL:-}" && { echo "Failed to lsf: pcloud said no" >&2; exit "${STUB_FAIL_RC:-1}"; }
hit "${STUB_GONE:-}" && { echo "directory not found" >&2; exit 3; }
# An hour of slack: probes in later waves run seconds after the collector's START.
echo "$(date -d "@$(( $(date +%s) - ${STUB_AGE:-1} * 86400 - 3600 ))" '+%Y-%m-%d %H:%M:%S')|${STUB_SIZE:-999999999}"
STUB
chmod +x "$BSTUBS/rclone"
export STUB_CALLS="$BSTUBS/calls"
scol() { : > "$STUB_CALLS"; RCLONE="$BSTUBS/rclone" CONF=/dev/null "$COL" servers; }
bf() { rm -f "$BSTAT"; scol; chk "$BF"; }
# within <secs> <desc>: the previous expect finished inside <secs> wall time
within() {
    if [ $((SECONDS - T0)) -le "$1" ]; then echo "  PASS: $2"; PASS=$((PASS + 1))
    else echo "  FAIL: $2 (took $((SECONDS - T0))s)"; FAIL=$((FAIL + 1)); fi
}
expect "all fresh" 0 "^BACKUPS OK - Weekly-1 15/15 fresh \\(worst 1d\\); Monthly-1 1d; Monthly-2 1d \\|.* stale=0 unknown=0 elapsed=[0-9]+s collected_age=" no -- bf
STUB_AGE=10 expect "weekly past warn" 1 "^BACKUPS WARNING - [a-z-]+: aging 10d \\(warn 9d\\) \\[\\+14 more\\]; Weekly-1 0/15" any -- bf
STUB_AGE=20 expect "weekly past crit" 2 "^BACKUPS CRITICAL - [a-z-]+: STALE 20d \\(crit 16d\\)" any -- bf
STUB_GONE=rt4.sql expect "missing dump is named on line 1" 2 "^BACKUPS CRITICAL - rt-db: MISSING \\(Weekly-1/rt.fatherlinux.com/data/backups/rt4.sql\\); Weekly-1 14/15" any -- bf
STUB_FAIL=rt4.sql STUB_FAIL_RC=5 expect "first-ever rclone error is UNKNOWN, not MISSING" 3 "^BACKUPS UNKNOWN - rt-db: RCLONE ERROR \\(exit 5\\): Failed to lsf: pcloud said no; .* unknown=1 " any -- bf
if [ "$(grep -c rt4.sql "$STUB_CALLS")" = 2 ]; then echo "  PASS: rclone error is retried once"; PASS=$((PASS + 1))
else echo "  FAIL: rclone error retried $(grep -c rt4.sql "$STUB_CALLS") times"; FAIL=$((FAIL + 1)); fi
T0=$SECONDS
STUB_SLOW=rt4.sql PROBE_T=1 BUDGET=4 expect "first-ever slow listing is UNKNOWN TIMEOUT, not MISSING" 3 "^BACKUPS UNKNOWN - rt-db: TIMEOUT after 1s" any -- bf
within 6 "timed-out listing stays inside the collector budget"
STUB_GONE=rt4.sql STUB_SLOW=feeds.db PROBE_T=1 BUDGET=8 \
    expect "MISSING outranks TIMEOUT" 2 "^BACKUPS CRITICAL - rt-db: MISSING .*\\[\\+1 more\\].*unknown=1 .*"$'\n'"rt-db: MISSING.*"$'\n'"mcp-feeds-db: TIMEOUT" any -- bf
STUB_SIZE=10 expect "shrunken dump" 2 "^BACKUPS CRITICAL - [a-z0-9-]+: TOO SMALL 10B" any -- bf
T0=$SECONDS
STUB_SLOW=lotor PROBE_T=2 BUDGET=3 expect "exhausted deadline leaves sentinels UNCHECKED" 3 "^BACKUPS UNKNOWN - [a-z0-9-]+: TIMEOUT .*, 19 unchecked;.*UNCHECKED \\(out of time\\)" any -- bf
within 4 "exhausted deadline does not overrun"
# The live-read failure this release exists for: a slow listing after a good run.
rm -f "$BSTAT"; scol
STUB_SLOW=crunchtools.com/backups PROBE_T=1 BUDGET=6 scol
expect "slow listing keeps the last real answer" 0 "^BACKUPS OK - Weekly-1 15/15 fresh" no -- chk "$BF"
sed -i -E "/item=monthly1-crunchtools /s/seen=[0-9]+/seen=$(( $(date +%s) - 7300 ))/" "$BSTAT"
expect "a sentinel unread for 2h is UNKNOWN by name" 3 "^BACKUPS UNKNOWN - monthly1-crunchtools: not read from pCloud for 2h" any -- chk "$BF"
rm -f "$BSTAT"; STUB_GONE=rt4.sql scol
sed -i -E "/item=rt-db /s/seen=[0-9]+/seen=$(( $(date +%s) - 7300 ))/" "$BSTAT"
expect "an old CRITICAL stays CRITICAL" 2 "^BACKUPS CRITICAL - rt-db: MISSING" any -- chk "$BF"
rm -f "$BSTAT"; STUB_AGE=20 scol; age_file "$BSTAT" 600
expect "stale backup in a fresh status file is CRITICAL" 2 "^BACKUPS CRITICAL - [a-z-]+: STALE 20d" no -- chk "$BF"
rm -f "$BSTAT"; scol; age_file "$BSTAT" 1500
expect "status past REFRESH is still judged and starts the collector" 0 "^BACKUPS OK" yes -- chk "$BF"
age_file "$BSTAT" 7300
expect "status older than 2h is UNKNOWN collector stale" 3 "^BACKUPS UNKNOWN - collector stale: last collection 2h" yes -- chk "$BF"
rm -f "$BSTAT"
expect "missing status file is UNKNOWN and starts the collector" 3 "^BACKUPS UNKNOWN - collector stale: no status file .*collector started" yes -- chk "$BF"
grep -q -- '--detach nagios-agent.crunchtools.com /collector servers' "$STUB_EXEC_MARK" \
    && { echo "  PASS: kick is a detached exec of the servers collector"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: kick args: $(cat "$STUB_EXEC_MARK")"; FAIL=$((FAIL + 1)); }
printf 'BKUP generated=%s elapsed=1\nBKUP item=rt-db rot=Weekly-1' "$(date +%s)" > "$BSTAT"
expect "truncated status file is UNKNOWN" 3 "^BACKUPS UNKNOWN - collector stale: .* truncated" yes -- chk "$BF"
# A second collector start while one runs must not race it for the file.
rm -f "$BSTAT"
( flock 9; sleep 3 ) 9>"$BSTATE/.servers.lock" &
sleep 0.5
expect "a second collector run exits while the first holds the lock" 0 "^$" any -- scol
[ -e "$BSTAT" ] && { echo "  FAIL: locked-out run wrote the status file"; FAIL=$((FAIL + 1)); }
wait
scol
[ "$(stat -c %a "$BSTAT")" = 644 ] && ! ls "$BSTATE"/*.tmp.* >/dev/null 2>&1 \
    && { echo "  PASS: status published 0644 with no temp file left"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: status mode $(stat -c %a "$BSTAT") or temp file left"; FAIL=$((FAIL + 1)); }
rm -rf "$BSTUBS" "$BSTATE" "$KSTUBS"
unset STATE_DIR

echo "=== podman_exec --detach ==="
DSTUBS="$(mktemp -d)"
cat > "$DSTUBS/curl" <<'STUB'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
    case "$1" in -d) data="$2"; shift ;; http://*) url="$1" ;; esac
    shift
done
echo "$url $data" >> "$STUB_CURL_LOG"
case "$url" in
    */start) printf '%s' "${STUB_START_CODE:-200}" ;;
    */exec) printf '{"Id":"abc123"}' ;;
esac
STUB
chmod +x "$DSTUBS/curl"
export STUB_CURL_LOG="$DSTUBS/log"
pxd() { : > "$STUB_CURL_LOG"; PATH="$DSTUBS:$PATH" "$LIBEXEC/podman_exec.sh" --detach "$@"; }
expect "detached start returns 0 with no output" 0 "^$" any -- pxd ctr /collector servers
grep -q '"Detach":true' "$STUB_CURL_LOG" && grep -q '"AttachStdout":false' "$STUB_CURL_LOG" && ! grep -q '/json' "$STUB_CURL_LOG" \
    && { echo "  PASS: detached exec does not attach or wait for an exit code"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: detached exec calls: $(cat "$STUB_CURL_LOG")"; FAIL=$((FAIL + 1)); }
STUB_START_CODE=404 expect "rejected detached start exits 3" 3 "EXEC_ERROR: detached start .* HTTP 404" any -- pxd ctr /collector servers
rm -rf "$DSTUBS"

echo "=== check_hermes_exec ==="
HX="$LIBEXEC/check_hermes_exec.sh"
export LIBEXEC
STUB_EXEC="OK - 2/2 platforms" STUB_EXEC_RC=0 expect "OK passes through" 0 "^OK - 2/2" yes -- "$HX" ctr check_hermes_platforms.py
STUB_EXEC="WARNING - filling" STUB_EXEC_RC=1 expect "WARNING passes through" 1 "^WARNING" yes -- "$HX" ctr check_hermes_context.py
STUB_EXEC="UNKNOWN - cannot query" STUB_EXEC_RC=3 expect "probe UNKNOWN passes through" 3 "^UNKNOWN" yes -- "$HX" ctr check_hermes_context.py
STUB_EXEC="EXEC_ERROR: Cannot create exec in container ctr" STUB_EXEC_RC=3 expect "exec failure fails closed" 2 "^CRITICAL - could not run" yes -- "$HX" ctr check_hermes_platforms.py
STUB_EXEC="" STUB_EXEC_RC=0 expect "empty output fails closed" 2 "^CRITICAL - could not run" yes -- "$HX" ctr check_hermes_platforms.py
STUB_EXEC="Traceback" STUB_EXEC_RC=137 expect "odd exit code is CRITICAL" 2 "exited 137" yes -- "$HX" ctr check_hermes_platforms.py
STUB_EXEC=$'Traceback (most recent call last):\n  File "x"\nSyntaxError: bad' STUB_EXEC_RC=1 expect "traceback is CRITICAL, not WARNING" 2 "^CRITICAL - check_hermes_platforms.py crashed.*SyntaxError" yes -- "$HX" ctr check_hermes_platforms.py
expect "missing probe is CRITICAL" 2 "^CRITICAL - probe .* is missing" no -- "$HX" ctr no_such_probe.py
expect "too few arguments is CRITICAL" 2 "^CRITICAL - usage" no -- "$HX" ctr
# The loader itself: run what the wrapper would send through a real python3.
LOADSTUB="$(mktemp -d)"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$LOADSTUB/exec.sh"; chmod +x "$LOADSTUB/exec.sh"
echo '[]' > "$LOADSTUB/gateway_state.json"  # valid JSON, wrong shape: the probe raises
PODMAN_EXEC="$LOADSTUB/exec.sh" expect "probe exception is CRITICAL through the loader" 2 "^CRITICAL - check_hermes_platforms.py crashed: AttributeError" any -- "$HX" ctr check_hermes_platforms.py "$LOADSTUB"
PODMAN_EXEC="$LOADSTUB/exec.sh" expect "base64 loader runs the probe with its args" 3 "^UNKNOWN - cannot read /nonexistent/gateway_state.json" any -- "$HX" ctr check_hermes_platforms.py /nonexistent
rm -rf "$LOADSTUB"

echo "=== check_container_restart ==="
# Two socket calls: container inspect returns $STUB_INSPECT, events returns
# $STUB_EVENTS (newline-delimited, as podman sends it with stream=false).
CSTUBS="$(mktemp -d)"
cat > "$CSTUBS/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in */events) printf '%s' "${STUB_EVENTS:-}"; exit "${STUB_EVENTS_RC:-0}" ;; esac
done
printf '%s' "$STUB_INSPECT"
STUB
chmod +x "$CSTUBS/curl"
CR="$LIBEXEC/check_container_restart.sh"
cr() { PATH="$CSTUBS:$PATH" "$CR" "$@"; }
started() { echo "{\"State\":{\"Status\":\"running\",\"Running\":true,\"StartedAt\":\"$(date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000000000Z)\"}}"; }
die() { echo "{\"status\":\"die\",\"id\":\"c$1\",\"Type\":\"container\",\"Action\":\"die\",\"Actor\":{\"ID\":\"c$1\",\"Attributes\":{\"containerExitCode\":\"$2\",\"name\":\"ctr\"}},\"time\":$1,\"timeNano\":${1}000000000}"; }
oom() { echo "{\"status\":\"oom\",\"id\":\"c$1\",\"Type\":\"container\",\"Action\":\"oom\",\"Actor\":{\"ID\":\"c$1\",\"Attributes\":{\"name\":\"ctr\"}},\"time\":$1,\"timeNano\":${1}000000000}"; }
T=$(date +%s)
STUB_INSPECT="$(started 86400)" expect "long uptime is OK" 0 "^OK - Container ctr up 1d" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(die $((T - 62)) 0)" expect "clean stop is OK" 0 "^OK .*clean stop \\(exit 0\\)" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(die $((T - 62)) 143)" expect "SIGTERM exit is OK" 0 "^OK .*exit 143" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(die $((T - 62)) 1)" expect "non-zero exit is CRITICAL" 2 "^CRITICAL .*exited 1" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(printf '%s\n%s' "$(oom $((T - 63)))" "$(die $((T - 62)) 137)")" \
    expect "OOM kill is CRITICAL" 2 "^CRITICAL .*OOM-killed" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(printf '%s\n%s' "$(die $((T - 62)) 0)" "$(die $((T - 900)) 1)")" \
    expect "verdict uses the newest death, not the last line" 0 "^OK .*exit 0" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(for i in 1 2 3 4; do die $((T - i * 600)) 0; done)" \
    expect "four clean deaths in an hour is a loop" 2 "^CRITICAL .*restart loop: 4 deaths in the hour" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(oom $((T - 63)))" expect "OOM without a die event still says OOM" 2 "^CRITICAL .*OOM-killed" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(die $((T - 62)) 0 | sed 's/"containerExitCode":"0",//')" \
    expect "die without an exit code is CRITICAL" 2 "^CRITICAL .*exited \\?" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(printf '%s\n%s' "$(die $((T - 900)) 1 | sed 's/"timeNano":[0-9]*/"timeNano":"bad"/')" "$(die $((T - 62)) 0)")" \
    expect "malformed timeNano loses to a dated death" 0 "^OK .*exit 0" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="" expect "no die event is CRITICAL" 2 "^CRITICAL .*cause unknown" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(die $((T - 62)) 0)" STUB_EVENTS_RC=28 \
    expect "events timeout is CRITICAL" 2 "^CRITICAL .*cause unknown .*curl exit 28" any -- cr ctr 300 0
STUB_INSPECT="$(started 60)" STUB_EVENTS="$(oom $((T - 63)))" STUB_EVENTS_RC=18 \
    expect "partial read with an OOM is not a confirmed OOM" 2 "^CRITICAL .*cause unknown .*curl exit 18" any -- cr ctr 300 0
STUB_INSPECT="$(started 600)" expect "outside crit window with warn 0 is OK" 0 "^OK - Container ctr up" any -- cr ctr 300 0
STUB_INSPECT="$(started 600)" expect "warn window still works when passed" 1 "^WARNING" any -- cr ctr 300 900
STUB_INSPECT='{"State":{"Status":"exited","Running":false}}' expect "stopped container is CRITICAL" 2 "^CRITICAL .*is exited" any -- cr ctr 300 0
expect "bad container name rejected" 3 "UNKNOWN - invalid container" any -- cr '../x"]}' 300 0
rm -rf "$CSTUBS"

echo "=== check_ondemand_unit ==="
# systemctl stub: is-system-running prints $STUB_SYSTEM; show prints the state
# for the unit's type from $STUB_SOCKET / $STUB_SERVICE / $STUB_PATH.
OSTUBS="$(mktemp -d)"
cat > "$OSTUBS/systemctl" <<'STUB'
#!/bin/bash
case "$1" in
    is-system-running) echo "${STUB_SYSTEM-running}"; exit 0 ;;
    show)
        unit="${!#}"
        case "$*" in *ActiveEnterTimestamp*) echo "Fri 2026-10-17 10:00:00 EDT"; exit 0 ;; esac
        case "$unit" in
            *.socket) echo "${STUB_SOCKET-active}" ;;
            *.path) echo "${STUB_PATH-active}" ;;
            *) echo "${STUB_SERVICE-inactive}" ;;
        esac ;;
esac
STUB
chmod +x "$OSTUBS/systemctl"
OU="$LIBEXEC/check_ondemand_unit.sh"
ou() { PATH="$OSTUBS:$PATH" "$OU" "$@"; }
expect "idle is OK" 0 "^OK .*idle, starts on demand" any -- ou d.socket d.service d.path
STUB_SERVICE=active expect "running is OK" 0 "^OK .*running since" any -- ou d.socket d.service d.path
STUB_SERVICE=activating expect "starting is OK" 0 "^OK .*starting" any -- ou d.socket d.service
STUB_SERVICE=failed expect "failed service is CRITICAL" 2 "^CRITICAL .*d.service failed" any -- ou d.socket d.service
STUB_SOCKET=inactive expect "socket down is CRITICAL" 2 "^CRITICAL - d.socket is inactive: nothing will start" any -- ou d.socket d.service
STUB_PATH=failed expect "path unit down is CRITICAL" 2 "^CRITICAL - d.path is failed" any -- ou d.socket d.service d.path
STUB_SYSTEM=offline expect "no host systemd is UNKNOWN, not idle" 3 "^UNKNOWN .*no reachable system manager" any -- ou d.socket d.service
STUB_SOCKET="" expect "unreadable state is UNKNOWN" 3 "^UNKNOWN - cannot read state of d.socket" any -- ou d.socket d.service
STUB_SERVICE=weird expect "unexpected state is WARNING" 1 "^WARNING .*is weird" any -- ou d.socket d.service
expect "missing args is UNKNOWN" 3 "^UNKNOWN - usage" any -- ou d.socket
expect "bad unit name rejected" 3 "^UNKNOWN - invalid unit" any -- ou 'x;rm.socket' d.service
rm -rf "$OSTUBS"

echo "=== check_container_memory ==="
CM="$LIBEXEC/check_container_memory.sh"
NOTFOUND='{"cause":"no such container","message":"no container with name or ID \"x\" found","response":404}'
STUB_SOCK="$NOTFOUND" expect "absent container is UNKNOWN by default" 3 "^UNKNOWN .*not found" any -- "$CM" x 85 95
STUB_SOCK="$NOTFOUND" expect "absent-ok makes it OK" 0 "^OK - x not running \\(on demand\\)" any -- "$CM" x 85 95 absent-ok
STUB_SOCK='{"cause":"connection refused","message":"cannot connect to podman","response":500}' \
    expect "absent-ok does not hide other API errors" 3 "^UNKNOWN" any -- "$CM" x 85 95 absent-ok
STUB_SOCK='{"memory_stats":{"usage":536870912,"limit":1073741824}}' expect "running container still measured with absent-ok" 0 "^OK - x memory 50%" any -- "$CM" x 85 95 absent-ok

echo "=== check_tig_trends ==="
TT="$LIBEXEC/check_tig_trends.sh"
STUB_EXEC='' expect "nothing firing is OK" 0 "^OK - no trend alert firing" yes -- "$TT"
STUB_EXEC=$'Disk fills within 7 days: /etc, /var\n' expect "a firing rule is WARNING" 1 "^WARNING - Disk fills within 7 days: /etc, /var \\| firing=1$" yes -- "$TT"
STUB_EXEC=$'Disk fills within 7 days: /var\nSwap grew more than 1 GiB in 6 hours: lotor\n' \
    expect "two rules are joined on one line" 1 "^WARNING - Disk.*/var; Swap.*lotor \\| firing=2$" yes -- "$TT"
STUB_EXEC="Disk fills within 7 days: $(printf '/p%03d, ' $(seq 1 100))" expect "long output is truncated" 1 "^WARNING - .{300}\\.\\.\\. \\| firing=1$" yes -- "$TT"
STUB_EXEC='cannot read Grafana alert rules: refused' STUB_EXEC_RC=1 expect "unreadable Grafana is UNKNOWN, never CRITICAL" 3 "^UNKNOWN - could not read Grafana alert rules" yes -- "$TT"

echo "=== mount-probe-collect (fake /proc/1) ==="
MPC="$LIBEXEC/mount-probe-collect.sh"
FP="$(mktemp -d)"
mkdir -p "$FP/root/var/mnt/pcloud/Documents/a" "$FP/root/var/mnt/pcloud/Empty" "$FP/slowfind"
touch "$FP/root/var/mnt/pcloud/Documents/b"
echo '3854 47 0:234 / /var/mnt/pcloud ro,nosuid,nodev shared:2524 - fuse.rclone pcloud: ro,user_id=0' > "$FP/mountinfo"
printf '#!/bin/bash\nsleep 5\n' > "$FP/slowfind/find"; chmod +x "$FP/slowfind/find"
PROC_ROOT="$FP" expect "mounted and listing" 0 "fstype=fuse.rclone.*list_rc=0 entries=2 .*end=1" any -- "$MPC" /var/mnt/pcloud Documents 5
PROC_ROOT="$FP" expect "missing subdir is a non-zero list_rc" 0 "list_rc=[1-9][0-9]* entries=0" any -- "$MPC" /var/mnt/pcloud Nope 5
PROC_ROOT="$FP" PATH="$FP/slowfind:$PATH" expect "hung listing is list_rc=124" 0 "list_rc=124" any -- "$MPC" /var/mnt/pcloud Documents 1
PROC_ROOT="$FP" expect "absent mount is mounted=0, no listing" 0 "^MPROBE mounted=0.MPROBE end=1$" any -- "$MPC" /var/mnt/other Documents 5
PROC_ROOT="$FP" expect "dotdot rejected" 0 "error=invalid_subdir" any -- "$MPC" /var/mnt/pcloud ../../etc 5
PROC_ROOT="$FP/nope" expect "no mountinfo is an error" 0 "error=no_host_mountinfo" any -- "$MPC" /var/mnt/pcloud Documents 5
rm -rf "$FP"

echo "=== check_fuse_mount ==="
FM="$LIBEXEC/check_fuse_mount.sh"
STUB_EXEC=$'MPROBE mounted=1 fstype=fuse.rclone\nMPROBE list_rc=0 entries=3 ms=420\nMPROBE end=1' \
    expect "mounted and listing is OK" 0 "^FUSE MOUNT OK - /var/mnt/pcloud \\(fuse.rclone\\): Documents lists 3 entries in 0.42s \\| entries=3;;1:;0 elapsed=0.42s;;10;0$" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC=$'MPROBE mounted=0\nMPROBE end=1' expect "not a mountpoint is CRITICAL" 2 "^FUSE MOUNT CRITICAL - /var/mnt/pcloud is not a mountpoint" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC=$'MPROBE mounted=1 fstype=fuse.rclone\nMPROBE list_rc=124 entries=0 ms=10002\nMPROBE end=1' \
    expect "timeout is CRITICAL" 2 "^FUSE MOUNT CRITICAL - listing .* timed out after 10s" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC=$'MPROBE mounted=1 fstype=fuse.rclone\nMPROBE list_rc=2 entries=0 ms=5\nMPROBE end=1' \
    expect "listing failure is CRITICAL" 2 "^FUSE MOUNT CRITICAL - listing .* failed, exit 2" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC=$'MPROBE mounted=1 fstype=fuse.rclone\nMPROBE list_rc=0 entries=0 ms=5\nMPROBE end=1' \
    expect "empty listing is CRITICAL" 2 "^FUSE MOUNT CRITICAL - .* lists empty" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC=$'MPROBE mounted=1 fstype=fuse.rclone' expect "truncated output is UNKNOWN" 3 "^FUSE MOUNT UNKNOWN - collector output truncated" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC=$'MPROBE error=no_host_mountinfo\nMPROBE end=1' expect "collector error is UNKNOWN" 3 "^FUSE MOUNT UNKNOWN - collector reported: no_host_mountinfo" yes -- "$FM" /var/mnt/pcloud Documents
STUB_EXEC_RC=3 expect "exec failure is UNKNOWN" 3 "^FUSE MOUNT UNKNOWN - collector exec .* exited 3" yes -- "$FM" /var/mnt/pcloud Documents
expect "missing args is UNKNOWN" 3 "^FUSE MOUNT UNKNOWN - usage" no -- "$FM" /var/mnt/pcloud
expect "dotdot rejected before exec" 3 "^FUSE MOUNT UNKNOWN - invalid" no -- "$FM" /var/mnt/pcloud ../etc
expect "bad timeout rejected" 3 "^FUSE MOUNT UNKNOWN - timeout" no -- "$FM" /var/mnt/pcloud Documents 0

echo "=== check_sqlite_rows ==="
SR="$LIBEXEC/check_sqlite_rows.sh"
if ! command -v sqlite3 >/dev/null; then
    echo "  FAIL: sqlite3 is required (check_sqlite_rows shells out to it)"
    FAIL=$((FAIL + 1))
else
    SQ="$(mktemp -d)"
    sqlite3 "$SQ/full.db" "PRAGMA journal_mode=WAL; CREATE TABLE files(id); INSERT INTO files VALUES (1),(2),(3);" >/dev/null
    sqlite3 "$SQ/empty.db" "CREATE TABLE files(id);"
    sqlite3 "$SQ/notable.db" "CREATE TABLE other(id);"
    expect "rows present is OK" 0 "^SQLITE OK - files has 3 rows .* \\| rows=3;;1:;0$" any -- "$SR" "$SQ/full.db" files
    expect "below min is CRITICAL" 2 "^SQLITE CRITICAL - files has 3 rows \\(min 5\\)" any -- "$SR" "$SQ/full.db" files 5
    expect "empty table is CRITICAL" 2 "^SQLITE CRITICAL - files has 0 rows \\(min 1\\)" any -- "$SR" "$SQ/empty.db" files
    expect "missing table is CRITICAL" 2 "^SQLITE CRITICAL - table files missing" any -- "$SR" "$SQ/notable.db" files
    expect "missing database is CRITICAL" 2 "^SQLITE CRITICAL - .* does not exist" any -- "$SR" "$SQ/nope.db" files
    [ -e "$SQ/nope.db" ] && { echo "  FAIL: a missing database was created"; FAIL=$((FAIL + 1)); }
    echo "not a database" > "$SQ/junk.db"
    expect "corrupt file is UNKNOWN" 3 "^SQLITE UNKNOWN - " any -- "$SR" "$SQ/junk.db" files
    expect "injected table name rejected" 3 "^SQLITE UNKNOWN - invalid table" any -- "$SR" "$SQ/full.db" 'files; DROP TABLE files'
    expect "URI metacharacters rejected" 3 "^SQLITE UNKNOWN - invalid database path" any -- "$SR" "$SQ/full.db?mode=rwc" files
    mkdir "$SQ/slow"; printf '#!/bin/bash\nsleep 5\n' > "$SQ/slow/sqlite3"; chmod +x "$SQ/slow/sqlite3"
    PATH="$SQ/slow:$PATH" SQLITE_TIMEOUT=1 expect "stalled query is UNKNOWN" 3 "^SQLITE UNKNOWN - query timed out after 1s" any -- "$SR" "$SQ/full.db" files
    rm -rf "$SQ"
fi

echo "=== check_trove_run ==="
TR="$LIBEXEC/check_trove_run.sh"
if ! command -v sqlite3 >/dev/null; then
    echo "  FAIL: sqlite3 is required (check_trove_run parses JSON with it)"
    FAIL=$((FAIL + 1))
else
    TD="$(mktemp -d)"
    NOW=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
    OLD=$(date -u -d '-40 hours' +%Y-%m-%dT%H:%M:%S+00:00)
    run_json() { # <name> <status> <finished> <problems> <paths> <calls> <backup>
        printf '{"status":"%s","finished_at":"%s","problems":%s,"paths":%s,"vision_calls":%s,"vision_budget":3000,"latest_backup":%s,"duration_seconds":60}\n' \
            "$2" "$3" "$4" "$5" "$6" "$7" > "$TD/$1.json"
    }
    P_OK='[{"path":"/a","status":"ok","files_found":100,"files_indexed":3,"files_errored":1,"files_deferred":0}]'
    P_ERR='[{"path":"/a","status":"ok","files_found":100,"files_indexed":3,"files_errored":8,"files_deferred":0}]'
    B_NOW="{\"file\":\"trove-x.db\",\"created_at\":\"$NOW\"}"
    run_json ok ok "$NOW" '[]' "$P_OK" 10 "$B_NOW"
    run_json stale ok "$OLD" '[]' "$P_OK" 10 "$B_NOW"
    run_json failed failed "$NOW" '["/pcloud is not mounted"]' '[{"path":"/b","status":"aborted"}]' 0 null
    run_json budget ok "$NOW" '[]' "$P_OK" 3000 "$B_NOW"
    run_json errors ok "$NOW" '[]' "$P_ERR" 1 "$B_NOW"
    run_json nobackup ok "$NOW" '[]' "$P_OK" 1 null
    P_DEF='[{"path":"/a","status":"ok","files_found":100,"files_indexed":3,"files_errored":0,"files_deferred":40}]'
    printf '{"status":"ok","finished_at":"%s","problems":[],"paths":%s,"vision_calls":12,"vision_budget":0,"vision_out_of_credit":true,"latest_backup":%s,"duration_seconds":60}\n' \
        "$NOW" "$P_DEF" "$B_NOW" > "$TD/nocredit.json"
    echo 'not json' > "$TD/junk.json"
    expect "clean recent run is OK" 0 "^TROVE RUN OK - finished 0.0h ago: 100 files, 3 indexed, 1 errored, 10 vision calls \\| age_hours=" any -- "$TR" "$TD/ok.json"
    expect "stale run is CRITICAL" 2 "^TROVE RUN CRITICAL - last index run finished 40.0h ago" any -- "$TR" "$TD/stale.json"
    expect "failed run names its problems" 2 "^TROVE RUN CRITICAL - last index run failed: /pcloud is not mounted; /b aborted" any -- "$TR" "$TD/failed.json"
    expect "spent budget is WARNING" 1 "^TROVE RUN WARNING - vision budget of 3000 calls spent" any -- "$TR" "$TD/budget.json"
    expect "error rate over 5% is WARNING" 1 "^TROVE RUN WARNING - 8 of 100 files failed" any -- "$TR" "$TD/errors.json"
    expect "out of credit is WARNING" 1 "^TROVE RUN WARNING - vision provider out of credit, 40 files deferred \\(top up the key\\)" any -- "$TR" "$TD/nocredit.json"
    expect "no backup recorded is WARNING" 1 "^TROVE RUN WARNING - no database backup recorded" any -- "$TR" "$TD/nobackup.json"
    expect "missing summary is CRITICAL" 2 "^TROVE RUN CRITICAL - no run summary" any -- "$TR" "$TD/nope.json"
    expect "invalid JSON is UNKNOWN" 3 "^TROVE RUN UNKNOWN - " any -- "$TR" "$TD/junk.json"
    expect "quote in path rejected" 3 "^TROVE RUN UNKNOWN - invalid summary path" any -- "$TR" "$TD/x');--.json"
    rm -rf "$TD"
fi

echo "=== check_deploy_drift ==="
# The plugin greps fields out of the socket JSON, so one stub body serves both
# the container list (Id) and the per-container inspect (the rest).
DD="$LIBEXEC/check_deploy_drift.sh"
ID=$(printf 'a%.0s' $(seq 64))
OLD_TS=$(( $(date +%s) - 40 * 3600 ))
ctr() { # <image-ref> <autoupdate> <digest>
    printf '{"Id":"%s","Name":"svc","ImageName":"%s","ImageDigest":"%s","Config":{"Labels":{"io.containers.autoupdate":"%s"}}}' \
        "$ID" "$1" "$3" "$2"
}
quay() { printf '{"tags":[{"name":"latest","manifest_digest":"%s","start_ts":%s}]}' "$1" "$2"; }
LATEST=quay.io/crunchtools/svc:latest
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:aa "$OLD_TS") \
    expect "running digest matches Quay is OK" 0 "^DEPLOY DRIFT OK - 1/1 " any -- "$DD"
STUB_SOCK=$(ctr $LATEST "" sha256:aa) \
    expect "no autoupdate label is unmanaged" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 1 unmanaged, 0 stale\. unmanaged \(no autoupdate label\): svc" any -- "$DD"
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:bb "$OLD_TS") \
    expect "digest behind Quay past grace is stale" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 0 unmanaged, 1 stale" any -- "$DD"
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:bb "$(date +%s)") \
    expect "digest behind Quay inside grace is OK" 0 "^DEPLOY DRIFT OK - 1/1 " any -- "$DD"
STUB_SOCK=$(ctr quay.io/crunchtools/svc@sha256:aa "" sha256:aa) \
    expect "digest pin is counted, not drift" 0 "^DEPLOY DRIFT OK - .*pinned=1" any -- "$DD"
STUB_SOCK=$(ctr ghcr.io/other/svc:latest "" sha256:aa) \
    expect "third-party image is ignored" 0 "^DEPLOY DRIFT OK - 0/0 " any -- "$DD"
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT_RC=22 \
    expect "Quay unreadable is UNKNOWN, never OK" 3 "^DEPLOY DRIFT UNKNOWN - 1/1 containers could not be checked\. unreadable: svc" any -- "$DD"
STUB_SOCK_RC=7 \
    expect "socket unreadable is UNKNOWN" 3 "^DEPLOY DRIFT UNKNOWN - cannot list containers" any -- "$DD"
expect "non-numeric grace is UNKNOWN" 3 "^DEPLOY DRIFT UNKNOWN - grace_hours" any -- "$DD" soon

echo "=== check_git_drift (grace) ==="
GD="$LIBEXEC/check_git_drift.sh"
srvdrift() { # <dirty> <drift_since epoch> [extra lines]
    printf 'SRVDRIFT generated=1\nSRVDRIFT dirty_files=%s\nSRVDRIFT unpushed=0\nSRVDRIFT drift_since=%s\nSRVDRIFT services=svc\n%sSRVDRIFT end=1\n' "$1" "$2" "${3:-}"
}
T=$(date +%s)
gd() { EXEC="$STUBS/podman_exec.sh" "$GD"; }
STUB_EXEC="$(srvdrift 0 0)" expect "clean tree is OK" 0 "^GIT DRIFT OK - /srv clean" yes -- gd
STUB_EXEC="$(srvdrift 2 $((T - 7200)))" expect "2h of drift is within grace" 0 "^GIT DRIFT OK - drift 2h, within grace \\(warn after 4h\\): /srv out of sync" yes -- gd
STUB_EXEC="$(srvdrift 2 $((T - 18000)))" expect "5h of drift is WARNING" 1 "^GIT DRIFT WARNING - /srv out of sync with git for 5h" yes -- gd
STUB_EXEC="$(srvdrift 2 $((T - 90000)))" expect "25h of drift is CRITICAL" 2 "^GIT DRIFT CRITICAL - " yes -- gd
STUB_EXEC="$(srvdrift 2 $((T - 7200)))" WARN=3600 expect "WARN env still overrides" 1 "^GIT DRIFT WARNING - " yes -- gd

echo "=== check_unit_drift (grace) ==="
UD="$LIBEXEC/check_unit_drift.sh"
units() { # <mismatch> <unbacked> [unit_drift_since]
    printf 'SRVDRIFT generated=1\nSRVDRIFT unit_mismatch=%s\nSRVDRIFT unit_unbacked=%s\nSRVDRIFT unit_list=a.service\n' "$1" "$2"
    [ -n "${3:-}" ] && printf 'SRVDRIFT unit_drift_since=%s\n' "$3"
    printf 'SRVDRIFT end=1\n'
}
ud() { EXEC="$STUBS/podman_exec.sh" "$UD"; }
STUB_EXEC="$(units 0 0 0)" expect "matching units are OK" 0 "^UNIT DRIFT OK - every running unit matches" yes -- ud
STUB_EXEC="$(units 1 0 $((T - 1800)))" expect "30m-old unit drift is within grace" 0 "^UNIT DRIFT OK - drift 30m, within grace \\(warn after 4h\\): 1 unit\\(s\\) differ from /srv \\(a.service\\)" yes -- ud
STUB_EXEC="$(units 1 1 $((T - 18000)))" expect "5h-old unit drift is WARNING" 1 "^UNIT DRIFT WARNING - drift 5h: 1 unit\\(s\\) differ from /srv, 1 unit\\(s\\) have no /srv copy" yes -- ud
STUB_EXEC="$(units 1 0)" expect "undated drift counts as aged" 1 "^UNIT DRIFT WARNING - drift 4h" yes -- ud
STUB_EXEC="$(units 1 0 $((T - 1800)))" WARN=600 expect "WARN env overrides the grace" 1 "^UNIT DRIFT WARNING - drift 30m" yes -- ud

echo "=== srv-drift-collect (unit_drift_since) ==="
SC="$(mktemp -d)"
mkdir -p "$SC/srv/a/config" "$SC/etc"; git init -q "$SC/srv"
printf 'ExecStart=/srv/a\n' > "$SC/srv/a/config/a.service"
printf 'ExecStart=/srv/a --changed\n' > "$SC/etc/a.service"
printf 'ExecStart=/srv/b\n' > "$SC/etc/b.service"
touch -d '@1000000000' "$SC/srv/a/config/a.service"; touch -d '@1000000500' "$SC/etc/a.service"
touch -d '@1000000300' "$SC/etc/b.service"
OUT=$(REPO="$SC/srv" UNITS="$SC/etc" "$LIBEXEC/srv-drift-collect.sh" 2>/dev/null)
if [[ $OUT == *"unit_mismatch=1"* && $OUT == *"unit_unbacked=1"* && $OUT == *"unit_drift_since=1000000300"* ]]; then
    echo "  PASS: oldest of (newer copy of each mismatch, /etc copy of each unbacked)"; PASS=$((PASS + 1))
else
    echo "  FAIL: collector unit dating: $(grep -E 'unit_|error' <<< "$OUT" | tr '\n' ' ')"; FAIL=$((FAIL + 1))
fi
rm -rf "$SC"

echo "=== check_plugin_drift (grace) ==="
PD="$LIBEXEC/check_plugin_drift.sh"
PDD="$(mktemp -d)"; mkdir "$PDD/live" "$PDD/rel"
for n in a b c; do echo "$n" > "$PDD/rel/check_$n.sh"; cp "$PDD/rel/check_$n.sh" "$PDD/live/"; done
pd() { PLUGIN_DRIFT_LIVE="$PDD/live" PLUGIN_DRIFT_RELEASED="$PDD/rel" "$PD"; }
expect "no drift is OK" 0 "^OK - all 3 plugins match" any -- pd
echo changed > "$PDD/live/check_a.sh"
expect "fresh edit is within grace" 0 "^PLUGIN DRIFT OK - drift 0m, within grace \\(warn after 4h\\): 1 differ .*modified\\(1\\): check_a.sh" any -- pd
touch -d '5 hours ago' "$PDD/live/check_a.sh"
expect "5h-old edit is WARNING" 1 "^PLUGIN DRIFT WARNING - drift 5h: 1 differ from the released image: modified\\(1\\): check_a.sh" any -- pd
touch "$PDD/live/check_a.sh"; touch -d '2 minutes ago' "$PDD/live/check_a.sh"
PLUGIN_DRIFT_WARN=60 expect "PLUGIN_DRIFT_WARN overrides the grace" 1 "^PLUGIN DRIFT WARNING - drift 2m" any -- pd
cp "$PDD/rel/check_a.sh" "$PDD/live/"; rm "$PDD/live/check_b.sh"
expect "fresh removal is within grace" 0 "^PLUGIN DRIFT OK - .*released-but-not-running\\(1\\): check_b.sh" any -- pd
touch -d '6 hours ago' "$PDD/live"
expect "old removal is WARNING, dated by the dir" 1 "^PLUGIN DRIFT WARNING - drift 6h: .*released-but-not-running\\(1\\)" any -- pd
echo new > "$PDD/live/check_new.sh"; touch -d '6 hours ago' "$PDD/live"
expect "one old item is enough to warn" 1 "^PLUGIN DRIFT WARNING - drift 6h: 2 differ" any -- pd
rm -rf "$PDD"

echo "=== check_registry_drift (grace) ==="
RD="$LIBEXEC/check_registry_drift.sh"
GSTUBS="$(mktemp -d)"
cat > "$GSTUBS/git" <<'STUB'
#!/bin/bash
[ -n "${STUB_GIT_SLOW:-}" ] && exec sleep 30
[ -n "${STUB_TAG:-}" ] && printf 'deadbeef\trefs/tags/v%s\n' "$STUB_TAG"
exit 0
STUB
cat > "$GSTUBS/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        --unix-socket) printf '%s' "${STUB_LOCAL:-[]}"; exit 0 ;;
        */tag/*) [ -n "${STUB_QUAY_FAIL:-}" ] && exit 22; printf '%s' "${STUB_QUAY:-}"; exit 0 ;;
        */token*) printf '{"token":"t"}'; exit 0 ;;
        */tags/list*) printf '%s' "${STUB_GHCR:-}"; exit 0 ;;
    esac
done
exit 22
STUB
chmod +x "$GSTUBS/git" "$GSTUBS/curl"
echo "svc svc" > "$GSTUBS/images.conf"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$GSTUBS/sock"
RDC="$LIBEXEC/registry-drift-collect.sh"
RDSTATE="$(mktemp -d)"
RDSTAT="$RDSTATE/registry-drift.status"
cat > "$GSTUBS/kick" <<'STUB'
#!/bin/bash
echo "$*" > "$STUB_EXEC_MARK"
STUB
chmod +x "$GSTUBS/kick"
# rdcol: one collector run; rdchk: judge its file; rd: both, from scratch
rdcol() { PATH="$GSTUBS:$PATH" STATE_DIR="$RDSTATE" REGISTRY_DRIFT_CONF="$GSTUBS/images.conf" REGISTRY_DRIFT_SOCK="$GSTUBS/sock" "$RDC"; }
rdchk() { STATE_DIR="$RDSTATE" EXEC="$GSTUBS/kick" COLLECT=/collector "$RD"; }
rd() { rm -f "$RDSTAT"; rdcol; rdchk; }
quayj() { # <start_ts> [name]: a tag listing shaped like Quay's, nested object included
    printf '{"tags": [{"name": "%s", "reversion": false, "start_ts": %s, "child_manifests_presence": {"sha256:aa": true}}, {"name": "latest", "start_ts": 1}]}' "${2:-1.2.0}" "$1"
}
GH_HAS='{"name":"crunchtools/svc","tags":["1.2.0","latest"]}'
GH_NOT='{"name":"crunchtools/svc","tags":["1.1.0","latest"]}'
STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 100)))" STUB_GHCR="$GH_HAS" \
    expect "both registries carry the tag" 0 "^REGISTRY DRIFT OK - 1/1 images carry" any -- rd
STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 3600)))" STUB_GHCR="$GH_NOT" \
    expect "GHCR lagging a 1h-old Quay push is within grace" 0 "^REGISTRY DRIFT OK - drift 1h, within grace \\(warn after 4h\\): 1/1 .*in grace: svc:1.2.0\\[ghcr\\]" any -- rd
STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 18000)))" STUB_GHCR="$GH_NOT" \
    expect "GHCR lagging a 5h-old Quay push is WARNING" 1 "^REGISTRY DRIFT WARNING - 1/1 images drifted: 0 untagged, 1 missing" any -- rd
STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 3600)))" STUB_GHCR="$GH_NOT" REGISTRY_DRIFT_WARN=600 \
    expect "REGISTRY_DRIFT_WARN overrides the grace" 1 "^REGISTRY DRIFT WARNING - " any -- rd
STUB_TAG=1.2.0 STUB_QUAY="$(quayj 1 1.1.0)" STUB_GHCR="$GH_HAS" \
    expect "missing from Quay with no local image warns at once" 1 "^REGISTRY DRIFT WARNING - .*missing: svc:1.2.0\\[quay\\]" any -- rd
if command -v sqlite3 >/dev/null; then
    STUB_TAG=1.2.0 STUB_QUAY="$(quayj 1 1.1.0)" STUB_GHCR="$GH_HAS" \
        STUB_LOCAL="[{\"Id\":\"x\",\"RepoTags\":[\"ghcr.io/crunchtools/svc:1.2.0\"],\"Created\":$((T - 1200)),\"Labels\":{\"a\":\"b\"}}]" \
        expect "missing from Quay, dated by a local image, is within grace" 0 "^REGISTRY DRIFT OK - drift 20m, within grace" any -- rd
fi
STUB_TAG="" STUB_QUAY="$(quayj 1)" STUB_GHCR="$GH_HAS" \
    expect "untagged repo always warns" 1 "^REGISTRY DRIFT WARNING - 1/1 images drifted: 1 untagged" any -- rd
echo "=== registry-drift-collect (status file, kick) ==="
printf 'svc svc\nsvc svc\n' > "$GSTUBS/images.conf"
STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 100)))" STUB_GHCR="$GH_HAS" \
    expect "a doubled conf line is counted once" 0 "^REGISTRY DRIFT OK - 1/1 images carry .* collected_age=" no -- rd
echo "svc svc" > "$GSTUBS/images.conf"
# The grace is measured when the file is judged, not when it was written.
rm -f "$RDSTAT"; STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 3600)))" STUB_GHCR="$GH_NOT" rdcol
expect "drift inside the grace is OK" 0 "^REGISTRY DRIFT OK - drift 1h, within grace" no -- rdchk
sed -i -E "s/since=[0-9]+/since=$((T - 18000))/" "$RDSTAT"
expect "the same drift past the grace is WARNING with no new read" 1 "^REGISTRY DRIFT WARNING - 1/1 images drifted: 0 untagged, 1 missing" no -- rdchk
rm -f "$RDSTAT"; STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 18000)))" STUB_GHCR="$GH_NOT" rdcol
STUB_TAG=1.2.0 STUB_QUAY_FAIL=1 STUB_GHCR="$GH_NOT" rdcol
expect "an unreadable registry keeps the last answer" 1 "^REGISTRY DRIFT WARNING - 1/1 images drifted: 0 untagged, 1 missing" no -- rdchk
sed -i -E "/item=svc /s/seen=[0-9]+/seen=$((T - 11000))/" "$RDSTAT"
expect "an answer older than STALE counts as unreadable" 3 "^REGISTRY DRIFT UNKNOWN - 1/1 images could not be checked. unreadable: svc\\(stale\\)" no -- rdchk
rm -f "$RDSTAT"; STUB_TAG=1.2.0 STUB_QUAY_FAIL=1 STUB_GHCR="$GH_NOT" rdcol
expect "first-ever unreadable registry is UNKNOWN" 3 "^REGISTRY DRIFT UNKNOWN - 1/1 images could not be checked. unreadable: svc\\(quay\\)" no -- rdchk
T0=$SECONDS
rm -f "$RDSTAT"; STUB_GIT_SLOW=1 BUDGET=1 REGISTRY_DRIFT_TIMEOUT=2 rdcol
ok_if "a hung git call stays inside the budget" [ $((SECONDS - T0)) -le 4 ]
expect "an image the budget cut off is UNKNOWN by name" 3 "unreadable: svc\\(budget\\)" no -- rdchk
rm -f "$RDSTAT"
PATH="$GSTUBS:$PATH" STATE_DIR="$RDSTATE" REGISTRY_DRIFT_CONF=/nonexistent "$RDC"
expect "unreadable image list is UNKNOWN" 3 "^REGISTRY DRIFT UNKNOWN - cannot read image list" no -- rdchk
rm -f "$RDSTAT"; STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 100)))" STUB_GHCR="$GH_HAS" rdcol
sed -i -E "s/generated=[0-9]+/generated=$((T - 2000))/" "$RDSTAT"
expect "status past REFRESH is still judged and starts the collector" 0 "^REGISTRY DRIFT OK" yes -- rdchk
sed -i -E "s/generated=[0-9]+/generated=$((T - 11000))/" "$RDSTAT"
expect "status past STALE is UNKNOWN collector stale" 3 "^REGISTRY DRIFT UNKNOWN - collector stale: last collection 3h" yes -- rdchk
rm -f "$RDSTAT"
expect "missing status is UNKNOWN and starts the collector" 3 "^REGISTRY DRIFT UNKNOWN - collector stale: no status file .*collector started" yes -- rdchk
grep -q -- '--detach nagios-agent-ctr.crunchtools.com /collector' "$STUB_EXEC_MARK" \
    && { echo "  PASS: kick is a detached exec in the ctr agent"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: kick args: $(cat "$STUB_EXEC_MARK")"; FAIL=$((FAIL + 1)); }
rm -rf "$GSTUBS" "$RDSTATE"

echo "=== remote collectors (7.1.0): shared stubs ==="
# Cloudflare, Quay, registry drift and Google OAuth checks judge status files
# their collectors write. The collectors are driven here directly with a curl
# stub routed by URL; the checks' detached kick goes through a stub that
# records its arguments in $STUB_EXEC_MARK.
RSTATE="$(mktemp -d)"
RSTUBS="$(mktemp -d)"
cat > "$RSTUBS/curl" <<'STUB'
#!/bin/bash
url="" mt=30 prev=""
for a in "$@"; do
    case "$a" in http://*|https://*) url="$a" ;; esac
    [ "$prev" = --max-time ] && mt=$a
    prev=$a
done
[ -n "${STUB_CURL_LOG:-}" ] && echo "$*" >> "$STUB_CURL_LOG"
inc=${STUB_INC-'{"incidents":[]}'}
case "$url" in
    */graphql)
        # Like curl, give up at --max-time with exit 28.
        [ -n "${STUB_GQL_SLOW:-}" ] && { sleep "$mt"; echo "curl: (28) Operation timed out" >&2; exit 28; }
        [ "${STUB_GQL_RC:-0}" -ne 0 ] && { echo "curl: (7) Failed to connect" >&2; exit "$STUB_GQL_RC"; }
        printf '%s' "${STUB_GQL:-}" ;;
    */incidents/unresolved.json)
        [ "${STUB_INC_RC:-0}" -ne 0 ] && { echo "curl: (6) Could not resolve host" >&2; exit "$STUB_INC_RC"; }
        printf '%s' "$inc" ;;
    */scheduled-maintenances/*) printf '%s' "${STUB_MAINT:-}" ;;
    */repository/*/tag/*)
        [ "${STUB_QUAY_RC:-0}" -ne 0 ] && { echo "curl: (28) Operation timed out" >&2; exit "$STUB_QUAY_RC"; }
        printf '%s' "${STUB_QUAYTAG:-}" ;;
    */containers/*/exec)
        [ -n "${STUB_NOEXEC:-}" ] && { printf '{"cause":"no such container"}'; exit 0; }
        printf '{"Id":"abc123"}' ;;
    */exec/*/start) printf '%s' "${STUB_OAUTH:-}" ;;
    *) exit 22 ;;
esac
exit 0
STUB
cat > "$RSTUBS/kick" <<'STUB'
#!/bin/bash
echo "$*" > "$STUB_EXEC_MARK"
exit "${STUB_KICK_RC:-0}"
STUB
chmod +x "$RSTUBS/curl" "$RSTUBS/kick"
# rchk <plugin> [args]: run a converted plugin against $RSTATE, kicking through the stub
rchk() { STATE_DIR="$RSTATE" EXEC="$RSTUBS/kick" COLLECT=/collector "$@"; }
# rcol <collector> [args]: run a collector against $RSTATE with the curl stub
rcol() { PATH="$RSTUBS:$PATH" STATE_DIR="$RSTATE" "$@"; }
kick_args() { # <desc> <regex>: the last kick's arguments match
    if [ -e "$STUB_EXEC_MARK" ] && grep -qE -- "$2" "$STUB_EXEC_MARK"; then echo "  PASS: $1"; PASS=$((PASS + 1))
    else echo "  FAIL: $1 (kick: $(cat "$STUB_EXEC_MARK" 2>/dev/null))"; FAIL=$((FAIL + 1)); fi
}
age_status() { # <file> <secs>: rewrite generated= and every seen= as <secs> ago
    local t=$(( $(date +%s) - $2 ))
    sed -i -E "s/generated=[0-9]+/generated=$t/; s/seen=[0-9]+/seen=$t/g" "$1"
}

echo "=== cloudflare-collect + check_cloudflare_status ==="
CFC="$LIBEXEC/cloudflare-collect.sh"
CFZ="$LIBEXEC/check_cloudflare_status.sh"
CFSTAT="$RSTATE/cloudflare.status"
ZID1=0123456789abcdef0123456789abcdef
ZID2=fedcba9876543210fedcba9876543210
printf '# domain zone-id\nexample.com %s\nexample.org %s\n' "$ZID1" "$ZID2" > "$RSTUBS/zones.conf"
printf 'tok-SECRET-123\n' > "$RSTUBS/cf.token"
export STUB_CURL_LOG="$RSTUBS/curl.log"
cfcol() { : > "$STUB_CURL_LOG"; CF_ZONES="$RSTUBS/zones.conf" CF_TOKEN="$RSTUBS/cf.token" rcol "$CFC"; }
cfz() { rm -f "$CFSTAT"; cfcol; rchk "$CFZ" "$@"; }
gql() { # <requests> <cached>
    printf '{"data":{"viewer":{"zones":[{"httpRequests1hGroups":[{"sum":{"cachedRequests":%s,"requests":%s}}]}]}},"errors":null}' "$2" "$1"
}
GQL_SUNSET='{"data":null,"errors":[{"message":"Zone Analytics API is sunset and replaced by GraphQL API","path":["viewer"]}]}'
STUB_GQL="$(gql 1000 250)" expect "fresh zone is OK with requests and cache ratio" 0 \
    "^OK - example.com: 1000 requests, 25% cached \\| requests=1000;;;0; cached_pct=25%;;;0;100 collected_age=" no -- cfz example.com
STUB_GQL='{"data":{"viewer":{"zones":[{"httpRequests1hGroups":[]}]}},"errors":null}' \
    expect "zero requests is OK no traffic" 0 "^OK - example.org: no traffic in last 24h \\| requests=0" no -- cfz example.org
STUB_GQL="$GQL_SUNSET" expect "API error is UNKNOWN, not OK no traffic" 3 \
    "^UNKNOWN - example.com: Cloudflare analytics read failed: api:Zone_Analytics_API_is_sunset" no -- cfz example.com
STUB_GQL='{"data":{"viewer":{"zones":[]}},"errors":null}' expect "zone the token cannot see is UNKNOWN" 3 \
    "zone_not_visible_to_token" no -- cfz example.com
ok_if "token is never on a curl command line" bash -c '! grep -q SECRET "$0"' "$STUB_CURL_LOG"
rm -f "$CFSTAT"; STUB_GQL="$(gql 1000 250)" cfcol
ok_if "status file carries no token and no zone ID" bash -c '! grep -qE "SECRET|$1|$2" "$0"' "$CFSTAT" "$ZID1" "$ZID2"
STUB_GQL_RC=7 cfcol
expect "failed read keeps the last answer" 0 "^OK - example.com: 1000 requests" no -- rchk "$CFZ" example.com
sed -i -E "/zone=example.com /s/seen=[0-9]+/seen=$(( $(date +%s) - 700 ))/" "$CFSTAT"
expect "a zone unread past STALE is UNKNOWN" 3 "^UNKNOWN - example.com: not read from Cloudflare for 0h11m" no -- rchk "$CFZ" example.com
T0=$SECONDS
rm -f "$CFSTAT"; STUB_GQL_SLOW=1 PROBE_T=1 BUDGET=3 cfcol
ok_if "a hung zone call stays inside the budget" [ $((SECONDS - T0)) -le 5 ]
expect "first-ever timeout is UNKNOWN" 3 "^UNKNOWN - example.com: Cloudflare analytics read failed: curl_exit_" any -- rchk "$CFZ" example.com
rm -f "$CFSTAT"; STUB_GQL="$(gql 1000 250)" cfcol
expect "domain not in the conf is UNKNOWN" 3 "^UNKNOWN - example.net is not collected" no -- rchk "$CFZ" example.net
age_status "$CFSTAT" 150
expect "status past REFRESH is still judged and starts the collector" 0 "^OK - example.com" yes -- rchk "$CFZ" example.com
age_status "$CFSTAT" 700
expect "status past STALE is UNKNOWN collector stale" 3 "^UNKNOWN - collector stale: last collection 0h11m ago" yes -- rchk "$CFZ" example.com
rm -f "$CFSTAT"
expect "missing status is UNKNOWN and starts the collector" 3 "^UNKNOWN - collector stale: no status file .*collector started" yes -- rchk "$CFZ" example.com
kick_args "kick is a detached exec in the ctr agent" '^--detach nagios-agent-ctr.crunchtools.com /collector$'
STUB_KICK_RC=3 expect "failed kick is reported" 3 "collector could not be started" yes -- rchk "$CFZ" example.com
printf 'CF generated=%s elapsed=1\nCF zone=example.com' "$(date +%s)" > "$CFSTAT"
expect "truncated status is UNKNOWN" 3 "^UNKNOWN - collector stale: .* truncated" yes -- rchk "$CFZ" example.com
rm -f "$CFSTAT"
( flock 9; sleep 3 ) 9>"$RSTATE/.cloudflare.lock" &
sleep 0.5
STUB_GQL="$(gql 1 1)" cfcol
ok_if "a second Cloudflare run exits while the first holds the lock" [ ! -e "$CFSTAT" ]
wait

echo "=== check_cloudflare_global ==="
CF="$LIBEXEC/check_cloudflare_global.sh"
cf_incident() {  # <name> <impact> <component>...
    local name="$1" impact="$2" comps="" c; shift 2
    for c in "$@"; do comps="${comps:+$comps,}{\"id\":\"x\",\"name\":\"$c\",\"status\":\"degraded_performance\"}"; done
    printf '{"id":"i","name":"%s","status":"investigating","impact":"%s","components":[%s]}' "$name" "$impact" "$comps"
}
cfg() { rm -f "$CFSTAT"; STUB_GQL="$(gql 1 0)" cfcol; rchk "$CF"; }
if ! command -v gawk >/dev/null; then
    echo "  FAIL: gawk is required (cloudflare-collect parses JSON with it)"
    FAIL=$((FAIL + 1))
else
    APAC=$(cf_incident "Network Performance Degradation - Asia-Pacific" minor "Network")
    WARP=$(cf_incident "Incorrect geo location for some WARP users" minor "WARP")
    CDN=$(cf_incident "Elevated cache errors" minor "CDN/Cache" "Network")
    DNS=$(cf_incident "Authoritative DNS failures" major "Authoritative DNS")
    STUB_INC='{"page":{"name":"Cloudflare"},"incidents":[]}' \
        expect "no incidents is OK" 0 "^OK - All Cloudflare systems operational" no -- cfg
    STUB_INC='{"incidents":[]}' STUB_MAINT='{"scheduled_maintenances":[{"name":"x"}],"incidents":[{"name":"DFW maintenance","impact":"maintenance"}]}' \
        expect "active maintenance is named in the OK line" 0 "^OK - No incidents. Maintenance: DFW maintenance" no -- cfg
    STUB_INC="{\"page\":{\"name\":\"Cloudflare\"},\"incidents\":[$APAC,$WARP]}" \
        expect "regional Network and WARP stay OK" 0 "^OK .*2 unrelated" no -- cfg
    STUB_INC="{\"page\":{\"name\":\"Cloudflare\"},\"incidents\":[$WARP,$CDN]}" \
        expect "minor CDN/Cache is WARNING" 1 "^WARNING - Cloudflare: Elevated cache errors \\[minor/investigating; CDN/Cache\\]" no -- cfg
    STUB_INC="{\"page\":{\"name\":\"Cloudflare\"},\"incidents\":[$DNS]}" \
        expect "major Authoritative DNS is CRITICAL" 2 "^CRITICAL .*Authoritative DNS failures" no -- cfg
    STUB_INC_RC=6 expect "status page unreachable on a first run is UNKNOWN" 3 "^UNKNOWN - Cannot reach Cloudflare status API \\(curl_exit_6" no -- cfg
    STUB_INC='<html>gateway</html>' expect "non-JSON status page is UNKNOWN, not OK" 3 "^UNKNOWN - Cannot reach Cloudflare status API" no -- cfg
    STUB_INC="{\"incidents\":[$DNS]}" STUB_GQL="$(gql 1 0)" cfcol
    STUB_INC_RC=6 STUB_GQL="$(gql 1 0)" cfcol
    expect "unreachable status page keeps the last incidents" 2 "^CRITICAL .*Authoritative DNS failures" no -- rchk "$CF"
    age_status "$CFSTAT" 700
    expect "status past STALE is UNKNOWN collector stale" 3 "^UNKNOWN - collector stale: last collection" yes -- rchk "$CF"
    rm -f "$CFSTAT"
    expect "missing status is UNKNOWN and starts the collector" 3 "^UNKNOWN - collector stale: no status file" yes -- rchk "$CF"
    # Every listed component must raise an alert on its own. Names were checked
    # against cloudflarestatus.com/api/v2/components.json when the list was set.
    while IFS= read -r COMP; do
        [ -n "$COMP" ] || continue
        STUB_INC="{\"incidents\":[$(cf_incident "Test incident" minor "$COMP")]}" \
            expect "listed component alerts: $COMP" 1 "^WARNING .*$COMP" no -- cfg
    done < <(sed -n '/^RELEVANT_COMPONENTS="/,/^"/p' "$CF" | sed '1d;$d')
fi
unset STUB_CURL_LOG

echo "=== quay-collect + check_quay_staleness ==="
QC="$LIBEXEC/quay-collect.sh"
QS="$LIBEXEC/check_quay_staleness.sh"
QSTAT="$RSTATE/quay.status"
cat > "$RSTUBS/nrpe.cfg" <<'CFG'
command[check_quay_a]=/usr/local/nagios/libexec/check_quay_staleness.sh example/alpha 8 latest
command[check_quay_b]=/usr/local/nagios/libexec/check_quay_staleness.sh example/beta 8 latest
CFG
qtag() { printf '{"tags": [{"name": "latest", "last_modified": "%s"}], "page": 1}' "$(date -u -d "@$(( $(date +%s) - $1 * 86400 - 60 ))" '+%a, %d %b %Y %H:%M:%S -0000')"; }
qcol() { NRPE_CFG="$RSTUBS/nrpe.cfg" rcol "$QC" "$@"; }
qs() { rm -f "$QSTAT"; qcol; rchk "$QS" "$@"; }
STUB_QUAYTAG="$(qtag 2)" expect "fresh tag is OK" 0 "^OK - example/alpha:latest is 2 days old \\| age=2d;8;;0$" no -- qs example/alpha 8 latest
ok_if "collector reads every image the NRPE config watches" grep -q 'item=example/beta:latest .*result=ok' "$QSTAT"
STUB_QUAYTAG="$(qtag 9)" expect "tag past max-days is WARNING" 1 "^WARNING - example/alpha:latest is 9 days old \\[threshold: 8d\\] \\| age=9d;8;;0$" no -- qs example/alpha 8 latest
STUB_QUAYTAG='{"tags": [], "page": 1}' expect "tag Quay does not have is UNKNOWN" 3 "^UNKNOWN - No tag data for example/alpha:latest" no -- qs example/alpha 8 latest
STUB_QUAY_RC=28 expect "first-ever Quay failure is UNKNOWN" 3 "^UNKNOWN - Cannot query Quay API for example/alpha:latest \\(curl_exit_28" no -- qs example/alpha 8 latest
rm -f "$QSTAT"; STUB_QUAYTAG="$(qtag 9)" qcol; STUB_QUAY_RC=28 qcol
expect "failed read keeps the last answer" 1 "^WARNING - example/alpha:latest is 9 days old" no -- rchk "$QS" example/alpha 8 latest
sed -i -E "/item=example\\/alpha:latest /s/seen=[0-9]+/seen=$(( $(date +%s) - 700 ))/" "$QSTAT"
expect "a tag unread past STALE is UNKNOWN" 3 "^UNKNOWN - Quay has not answered for example/alpha:latest in 0h11m" no -- rchk "$QS" example/alpha 8 latest
rm -f "$QSTAT"; STUB_QUAYTAG="$(qtag 1)" qcol
expect "image not in the file is UNKNOWN and is kicked by name" 3 "^UNKNOWN - example/gamma:v1 is not collected yet \\(collector started\\)" yes -- rchk "$QS" example/gamma 8 v1
kick_args "kick carries the image" '^--detach nagios-agent-ctr.crunchtools.com /collector example/gamma v1$'
STUB_QUAYTAG="$(qtag 1)" qcol example/gamma v1
expect "an image named by a kick is collected" 0 "^OK - example/gamma:v1 is 1 days old" no -- rchk "$QS" example/gamma 8 v1
age_status "$QSTAT" 150
expect "status past REFRESH is still judged and starts the collector" 0 "^OK - example/alpha:latest" yes -- rchk "$QS" example/alpha 8 latest
age_status "$QSTAT" 700
expect "status past STALE is UNKNOWN collector stale" 3 "^UNKNOWN - collector stale: last collection 0h11m" yes -- rchk "$QS" example/alpha 8 latest
rm -f "$QSTAT"
expect "missing status is UNKNOWN and starts the collector" 3 "^UNKNOWN - collector stale: no status file .*collector started" yes -- rchk "$QS" example/alpha 8 latest
expect "bad repo argument is rejected" 3 "^UNKNOWN - usage" no -- rchk "$QS" '../x' 8 latest

echo "=== google-oauth-collect + check_google_oauth ==="
GC="$LIBEXEC/google-oauth-collect.sh"
GO="$LIBEXEC/check_google_oauth.sh"
GSTAT="$RSTATE/google-oauth.status"
printf '# key container credential label\npersonal ctr-a /cred/a.json alice@example.com\nwork ctr-b /cred/b.json bob@example.org\n' > "$RSTUBS/accounts.conf"
gcol() { GOOGLE_ACCOUNTS="$RSTUBS/accounts.conf" rcol "$GC"; }
gchk() { GOOGLE_ACCOUNTS="$RSTUBS/accounts.conf" rchk "$GO" "$@"; }
go() { rm -f "$GSTAT"; gcol; gchk "$@"; }
STUB_OAUTH=$'\x01\x02\x12OAUTH|200|3599\r\n' expect "valid token is OK" 0 \
    "^OK - alice@example.com: refresh token valid \\(access token good for 3599s\\) \\| token_ok=1$" no -- go personal
ok_if "both accounts are collected in one pass" grep -q 'key=work .*result=200' "$GSTAT"
STUB_OAUTH='OAUTH|400|invalid_grant' expect "rejected token is CRITICAL" 2 \
    "^CRITICAL - bob@example.org: refresh token REJECTED \\(HTTP 400 invalid_grant\\)" no -- go work
STUB_OAUTH='OAUTH|NOTOKEN|refresh_token' expect "credential without a token is CRITICAL" 2 "^CRITICAL - alice@example.com: credential file holds no usable refresh token" no -- go personal
STUB_OAUTH='OAUTH|NET|URLError' expect "first-ever network failure is UNKNOWN" 3 "^UNKNOWN - alice@example.com: ctr-a could not reach Google \\(URLError\\)" no -- go personal
STUB_NOEXEC=1 expect "backend not answering is UNKNOWN" 3 "^UNKNOWN - alice@example.com: could not create exec in ctr-a" no -- go personal
rm -f "$GSTAT"; STUB_OAUTH='OAUTH|200|3599' gcol; STUB_OAUTH='OAUTH|503|unknown' gcol
expect "a Google 5xx keeps the last answer" 0 "^OK - alice@example.com: refresh token valid" no -- gchk personal
sed -i -E "/key=personal /s/seen=[0-9]+/seen=$(( $(date +%s) - 700 ))/" "$GSTAT"
expect "an answer older than STALE is UNKNOWN" 3 "^UNKNOWN - alice@example.com: token not tested for 0h11m \\(last: 200 3599\\)" no -- gchk personal
rm -f "$GSTAT"; STUB_OAUTH='OAUTH|401|unauthorized_client' gcol; STUB_OAUTH='OAUTH|NET|timeout' gcol
sed -i -E "s/seen=[0-9]+/seen=$(( $(date +%s) - 700 ))/" "$GSTAT"
expect "an old rejection stays CRITICAL" 2 "^CRITICAL - alice@example.com: refresh token REJECTED \\(HTTP 401" no -- gchk personal
rm -f "$GSTAT"; STUB_OAUTH='OAUTH|200|3599' gcol; age_status "$GSTAT" 150
expect "status past REFRESH is still judged and starts the collector" 0 "^OK - alice@example.com" yes -- gchk personal
age_status "$GSTAT" 700
expect "status past STALE is UNKNOWN collector stale" 3 "^UNKNOWN - collector stale: last collection 0h11m" yes -- gchk personal
rm -f "$GSTAT"
expect "missing status is UNKNOWN and starts the collector" 3 "^UNKNOWN - collector stale: no status file .*collector started" yes -- gchk personal
expect "unknown account key is UNKNOWN" 3 "^UNKNOWN - account key 'nobody' not found" no -- gchk nobody
rm -rf "$RSTATE" "$RSTUBS"

echo "=== check_container_postgres ==="
PG="$LIBEXEC/check_container_postgres.sh"
STUB_EXEC='exec: "pg_isready": executable file not found in $PATH' STUB_EXEC_RC=127 \
    expect "pg_isready missing is UNKNOWN, not an outage" 3 "^UNKNOWN - pg_isready missing from image ctr$" yes -- "$PG" ctr
STUB_EXEC='localhost:5432 - no response' STUB_EXEC_RC=2 \
    expect "no response is still CRITICAL" 2 "^CRITICAL - PostgreSQL in ctr not accepting connections" yes -- "$PG" ctr
STUB_EXEC='7' STUB_EXEC_RC=0 expect "accepting with few connections is OK" 0 "^OK - PostgreSQL in ctr: 7 active" yes -- "$PG" ctr

echo "=== Hermes probes (python unittest) ==="
if UT=$(python3 -m unittest -q "$HERE/test_hermes_probes.py" 2>&1); then
    echo "  PASS: probe unit tests ($(echo "$UT" | grep -o 'Ran [0-9]* tests'))"; PASS=$((PASS + 1))
else
    echo "  FAIL: probe unit tests"; echo "$UT" | tail -20; FAIL=$((FAIL + 1))
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
