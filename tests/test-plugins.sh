#!/bin/bash
# Offline tests for the exec-free container plugins (RT #1513), the
# Cloudflare component filter and the personal backup markers. curl, rclone and
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

echo "=== check_cloudflare_global ==="
CF="$LIBEXEC/check_cloudflare_global.sh"
cf_incident() {  # <name> <impact> <component>...
    local name="$1" impact="$2" comps="" c; shift 2
    for c in "$@"; do comps="${comps:+$comps,}{\"id\":\"x\",\"name\":\"$c\",\"status\":\"degraded_performance\"}"; done
    printf '{"id":"i","name":"%s","status":"investigating","impact":"%s","components":[%s]}' "$name" "$impact" "$comps"
}
if ! command -v gawk >/dev/null; then
    echo "  FAIL: gawk is required (check_cloudflare_global parses JSON with it)"
    FAIL=$((FAIL + 1))
else
    APAC=$(cf_incident "Network Performance Degradation - Asia-Pacific" minor "Network")
    WARP=$(cf_incident "Incorrect geo location for some WARP users" minor "WARP")
    CDN=$(cf_incident "Elevated cache errors" minor "CDN/Cache" "Network")
    DNS=$(cf_incident "Authoritative DNS failures" major "Authoritative DNS")
    STUB_DIRECT="{\"page\":{\"name\":\"Cloudflare\"},\"incidents\":[$APAC,$WARP]}" \
        expect "regional Network and WARP stay OK" 0 "^OK .*2 unrelated" no -- "$CF"
    STUB_DIRECT="{\"page\":{\"name\":\"Cloudflare\"},\"incidents\":[$WARP,$CDN]}" \
        expect "minor CDN/Cache is WARNING" 1 "^WARNING .*Elevated cache errors.*CDN/Cache" no -- "$CF"
    STUB_DIRECT="{\"page\":{\"name\":\"Cloudflare\"},\"incidents\":[$DNS]}" \
        expect "major Authoritative DNS is CRITICAL" 2 "^CRITICAL .*Authoritative DNS failures" no -- "$CF"
    STUB_DIRECT='' expect "no response is UNKNOWN" 3 "^UNKNOWN" no -- "$CF"
    # Every listed component must raise an alert on its own. Names were checked
    # against cloudflarestatus.com/api/v2/components.json when the list was set.
    while IFS= read -r COMP; do
        [ -n "$COMP" ] || continue
        STUB_DIRECT="{\"incidents\":[$(cf_incident "Test incident" minor "$COMP")]}" \
            expect "listed component alerts: $COMP" 1 "^WARNING .*$COMP" no -- "$CF"
    done < <(sed -n '/^RELEVANT_COMPONENTS="/,/^"/p' "$CF" | sed '1d;$d')
fi

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

echo "=== check_personal_backup_freshness ==="
PB="$LIBEXEC/check_personal_backup_freshness.sh"
RSTUBS="$(mktemp -d)"
cat > "$RSTUBS/rclone" <<'STUB'
#!/bin/bash
printf '%s' "${STUB_MARKERS:-}"
exit "${STUB_RCLONE_RC:-0}"
STUB
chmod +x "$RSTUBS/rclone"
pb() { RCLONE="$RSTUBS/rclone" CONF=/dev/null "$PB"; }
# markers <weekly age days> <monthly age days> [rclone exit]: all twelve markers
markers() {
    local now; now=$(date +%s)
    for d in Documents Downloads Autosync Projects; do
        echo "Files|$d|Weekly-1|0|$((now - $1 * 86400))|${3:-0}"
        echo "Files|$d|Monthly-1|0|$((now - $2 * 86400))|0"
        echo "Files|$d|Monthly-2|0|$((now - $2 * 86400))|0"
    done
}
STUB_MARKERS="$(markers 2 40)" expect "all twelve fresh" 0 "OK - Weekly-1 4/4 fresh \\(worst 2d\\); Monthly-1 4/4 .*problems=0" any -- pb
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
STUB_MARKERS="" STUB_RCLONE_RC=124 expect "timeout is UNKNOWN" 3 "UNKNOWN - timed out" any -- pb
RCLONE=/nonexistent expect "rclone not mounted is UNKNOWN" 3 "UNKNOWN .*not mounted" any -- "$PB"
rm -rf "$RSTUBS"

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
    expect "events timeout is CRITICAL" 2 "^CRITICAL .*cause unknown" any -- cr ctr 300 0
STUB_INSPECT="$(started 600)" expect "outside crit window with warn 0 is OK" 0 "^OK - Container ctr up" any -- cr ctr 300 0
STUB_INSPECT="$(started 600)" expect "warn window still works when passed" 1 "^WARNING" any -- cr ctr 300 900
STUB_INSPECT='{"State":{"Status":"exited","Running":false}}' expect "stopped container is CRITICAL" 2 "^CRITICAL .*is exited" any -- cr ctr 300 0
expect "bad container name rejected" 3 "UNKNOWN - invalid container" any -- cr '../x"]}' 300 0
rm -rf "$CSTUBS"

echo "=== Hermes probes (python unittest) ==="
if UT=$(python3 -m unittest -q "$HERE/test_hermes_probes.py" 2>&1); then
    echo "  PASS: probe unit tests ($(echo "$UT" | grep -o 'Ran [0-9]* tests'))"; PASS=$((PASS + 1))
else
    echo "  FAIL: probe unit tests"; echo "$UT" | tail -20; FAIL=$((FAIL + 1))
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
