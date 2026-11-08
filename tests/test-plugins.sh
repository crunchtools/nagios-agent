#!/bin/bash
# Offline tests for the exec-free container plugins (RT #1513), the
# collector + status-file checks (backups, Cloudflare, Quay, registry drift,
# deploy drift, config drift, Google OAuth) and the Cloudflare component
# filter. curl, rclone and podman_exec.sh are stubbed, so this runs anywhere
# with bash, git and GNU grep -P, no Podman socket needed.
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
# STUB_SOCK answers every socket call, unless STUB_SOCK_TOKEN is set and the
# URL contains it, in which case STUB_SOCK_ALT answers instead. Two containers
# inspected in one plugin need two answers.
#
# STUB_SOCK_ALT_RC gives the matched call its own exit status, which is how a
# LISTING THAT SUCCEEDS and an INSPECT THAT FAILS are told apart: a token of
# the container id matches only the per-container URL, because the list is
# `containers/json` with no id in it. Without that, STUB_SOCK_RC fails both and
# the collector takes the keep-the-whole-previous-file path instead of the
# per-container one.
for a in "$@"; do
    if [ "$a" = "--unix-socket" ]; then
        url="${@: -1}"
        if [ -n "${STUB_SOCK_TOKEN:-}" ] && [ "${url#*$STUB_SOCK_TOKEN}" != "$url" ]; then
            printf '%s' "${STUB_SOCK_ALT:-}"
            exit "${STUB_SOCK_ALT_RC:-${STUB_SOCK_RC:-0}}"
        fi
        printf '%s' "${STUB_SOCK:-}"
        exit "${STUB_SOCK_RC:-0}"
    fi
done
printf '%s' "${@: -1}" > "$STUB_DIRECT_URL"
printf '%s' "${STUB_DIRECT:-}"
exit "${STUB_DIRECT_RC:-0}"
STUB
# ip stub: "route get <addr>" answers via a gateway for the addresses listed
# in STUB_ROUTED_VIA (no host route), on a local bridge for any other.
cat > "$STUBS/ip" <<'STUB'
#!/bin/bash
addr="${*: -1}"
case " ${STUB_ROUTED_VIA:-} " in
    *" $addr "*) echo "$addr via 192.0.2.1 dev eth0 src 192.0.2.10 uid 0" ;;
    *) echo "$addr dev podman0 src 10.88.0.1 uid 0" ;;
esac
STUB
cat > "$STUBS/podman_exec.sh" <<'STUB'
#!/bin/bash
touch "$STUB_EXEC_MARK"
printf '%s' "${STUB_EXEC:-}"
exit "${STUB_EXEC_RC:-0}"
STUB
chmod +x "$STUBS/curl" "$STUBS/podman_exec.sh" "$STUBS/ip"
export PATH="$STUBS:$PATH" PODMAN_EXEC="$STUBS/podman_exec.sh" STUB_EXEC_MARK="$STUBS/exec-ran" STUB_DIRECT_URL="$STUBS/direct-url"

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

echo "=== check_agent_gateway_stale ==="
GS="$LIBEXEC/check_agent_gateway_stale.sh"
# Times are built with the same `date` the plugin parses with, so the pair
# agrees whichever coreutils is installed (ubuntu-26.04 runners ship uutils).
iso_ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000000000Z; }
started() { printf '{"State":{"Running":true,"StartedAt":"%s"}}' "$(iso_ago "$1")"; }
# Same second, gateway later by a fraction: whole-second arithmetic called this
# healthy for ever.
same_second() { printf '{"State":{"Running":true,"StartedAt":"%sT00:00:00.%09d-05:00"}}' 2026-11-01 "$1"; }
STOPPED_JSON='{"State":{"Running":false,"StartedAt":"2026-11-01T00:00:00.000000000Z"}}'
export STUB_SOCK_TOKEN=trentina
# Agent started after the gateway: its MCP client is current.
STUB_SOCK="$(started 300)" STUB_SOCK_ALT="$(started 600)" \
    expect "agent newer than the gateway is OK" 0 "OK .*MCP client is current" any -- "$GS" agent trentina 900
# Gateway restarted after the agent and is past the grace: the client is gone.
STUB_SOCK="$(started 7200)" STUB_SOCK_ALT="$(started 3600)" \
    expect "gateway newer, past grace, is CRITICAL" 2 "CRITICAL .*lost its MCP client" any -- "$GS" agent trentina 900
# Same shape, but the gateway came up seconds ago: a restart sequence in
# progress must not page.
STUB_SOCK="$(started 7200)" STUB_SOCK_ALT="$(started 60)" \
    expect "gateway newer, inside grace, is OK" 0 "OK .*inside the 900s grace" any -- "$GS" agent trentina 900
STUB_SOCK="$(same_second 100000000)" STUB_SOCK_ALT="$(same_second 900000000)" \
    expect "gateway later within the same second is still CRITICAL" 2 "CRITICAL .*lost its MCP client" any -- "$GS" agent trentina 900
STUB_SOCK="$(same_second 900000000)" STUB_SOCK_ALT="$(same_second 100000000)" \
    expect "agent later within the same second is OK" 0 "OK .*MCP client is current" any -- "$GS" agent trentina 900
STUB_SOCK="$STOPPED_JSON" STUB_SOCK_ALT="$(started 60)" \
    expect "a stopped agent is CRITICAL" 2 "CRITICAL .*not running" any -- "$GS" agent trentina 900
STUB_SOCK="$(started 300)" STUB_SOCK_ALT="$STOPPED_JSON" \
    expect "a stopped gateway is UNKNOWN, not the agent's fault" 3 "UNKNOWN .*not running" any -- "$GS" agent trentina 900
STUB_SOCK="$(started 300)" \
    STUB_SOCK_ALT='{"cause":"no such container","message":"no container with name or ID \"trentina\" found","response":404}' \
    expect "a missing gateway is UNKNOWN" 3 "UNKNOWN .*no container" any -- "$GS" agent trentina 900
STUB_SOCK='{"cause":"no such container","message":"no container with name or ID \"agent\" found","response":404}' \
    expect "a missing agent is CRITICAL, with the whole reason" 2 'CRITICAL .*no container with name or ID "agent" found' any -- "$GS" agent trentina 900
STUB_SOCK_RC=28 expect "socket timeout is UNKNOWN" 3 "UNKNOWN .*curl exit 28" any -- "$GS" agent trentina 900
expect "bad container name rejected" 3 "UNKNOWN - invalid container" any -- "$GS" '../../x#' trentina 900
expect "a non-numeric grace is rejected" 3 "UNKNOWN - grace" any -- "$GS" agent trentina abc
unset STUB_SOCK_TOKEN

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
MULTI='{"NetworkSettings":{"IPAddress":"","Networks":{"crunchtools-rt":{"IPAddress":"10.89.20.2"},"podman":{"IPAddress":"10.88.0.14"}}}}'
STUB_SOCK="$MULTI" STUB_ROUTED_VIA="10.89.20.2" STUB_DIRECT="200 0.01" \
    expect "internal-network address is skipped" 0 "OK .*200" no -- "$HTTP" ctr 80 /
ok_if "probe used the bridge address" grep -q "^http://10.88.0.14:80/$" "$STUB_DIRECT_URL"
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

echo "=== cl_producer_running (in-flight guard, RT #1566) ==="
# The guard the backup collector leans on, exercised directly: it is the piece
# that decides whether "not at the destination" means MISSING or "still being
# written". Through the plugin, yes/no/unknown cannot all be told apart (unknown
# deliberately falls through to MISSING), so the boundaries are asserted here.
( . "$LIBEXEC/collector-lib.sh"
  pr() { # <desc> <expected> ; STUB_SOCK / STUB_SOCK_RC set by the caller
      local got; got=$(cl_producer_running pbs-server)
      if [ "$got" = "$2" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got $got, want $2)"; fi
  }
  STUB_SOCK='[{"Names":["/pbs-server-weekly"]}]'                 pr "a matching container is running"            yes
  STUB_SOCK='[{"Names":["/pbs-server-monthly-1"]}]'              pr "prefix matches a different name shape"       yes
  STUB_SOCK='[]'                                                 pr "empty array means nothing is running"        no
  STUB_SOCK='[{"Names":["/mcp-grafana"]}]'                       pr "unrelated containers mean no"                no
  STUB_SOCK='[{"Names":["/pbs-personal-weekly"]}]'               pr "another prefix does not match"               no
  STUB_SOCK='[{"Names":["/my-pbs-server-decoy"]}]'               pr "name must START with the prefix"             no
  STUB_SOCK='[{"Names":["/pbs-server-weekly"]}]' STUB_SOCK_RC=22 pr "HTTP error status is unknown, not no"        unknown
  STUB_SOCK=''                                                   pr "empty body is unknown"                       unknown
  STUB_SOCK='<html>502 Bad Gateway</html>'                       pr "HTML error body is unknown"                  unknown
  STUB_SOCK='[{"Names":["/pbs-server-weekly"'                    pr "truncated array is unknown, not yes"         unknown
  STUB_SOCK='[{"Names":["/mcp-grafana"]},{"Nam'                  pr "truncated before the match is unknown"       unknown
  STUB_SOCK='[{"Names":["/pbs-server-weekly"]}]
'                                                                pr "trailing newline still parses"               yes
) > "$STUBS/pr-out" 2>&1
cat "$STUBS/pr-out"
PASS=$((PASS + $(grep -c '^  PASS:' "$STUBS/pr-out")))
FAIL=$((FAIL + $(grep -c '^  FAIL:' "$STUBS/pr-out")))

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
# markers <weekly age days> <monthly age days> [rclone exit]: all nine markers
markers() {
    local now; now=$(date +%s)
    for d in Documents Downloads Autosync; do
        echo "Files|$d|Weekly-1|0|$((now - $1 * 86400))|${3:-0}"
        echo "Files|$d|Monthly-1|0|$((now - $2 * 86400))|0"
        echo "Files|$d|Monthly-2|0|$((now - $2 * 86400))|0"
    done
}
STUB_MARKERS="$(markers 2 40)" expect "all nine fresh" 0 "OK - Weekly-1 3/3 fresh \\(worst 2d\\); Monthly-1 3/3 .*problems=0" no -- pb
STUB_MARKERS="$(markers 10 40)" expect "weekly past warn" 1 "WARNING .*Documents/Weekly-1: aging 10d" any -- pb
STUB_MARKERS="$(markers 16 40)" expect "weekly past crit" 2 "CRITICAL .*Autosync/Weekly-1: STALE 16d" any -- pb
STUB_MARKERS="$(markers 2 69)" expect "monthly just inside warn" 0 "OK .*Monthly-2 3/3" any -- pb
STUB_MARKERS="$(markers 2 100)" expect "monthly past crit" 2 "CRITICAL .*Autosync/Monthly-1: STALE 100d" any -- pb
STUB_MARKERS="$(markers 0 40 3)" expect "fresh but failed run is CRITICAL" 2 "CRITICAL .*last run FAILED \\(rclone exit 3\\), 0d ago" any -- pb
STUB_MARKERS="$(markers 2 40 | grep -v 'Downloads|Monthly-2')" \
    expect "one missing marker" 2 "CRITICAL .*Monthly-2 2/3 .*Downloads/Monthly-2: MISSING marker" any -- pb
STUB_MARKERS="$(markers 2 40 | sed 's/^Files|Autosync|Weekly-1|.*/Files|Autosync|Weekly-1|oops/')" \
    expect "garbled marker" 2 "CRITICAL .*Autosync/Weekly-1: unreadable marker" any -- pb
STUB_MARKERS="" STUB_RCLONE_RC=3 expect "no markers at all" 2 "CRITICAL - cannot read markers .*rclone exit 3" any -- pb
STUB_MARKERS="" expect "empty folder" 2 "CRITICAL - cannot read markers .*rclone exit 0" any -- pb
STUB_MARKERS="$(markers 2 40)" STUB_RCLONE_RC=1 expect "failed read is not judged on partial output" 2 "CRITICAL - cannot read markers .*rclone exit 1" any -- pb
STUB_MARKERS="" STUB_RCLONE_RC=124 expect "first-ever read timing out is UNKNOWN" 3 "UNKNOWN - collector timed out" any -- pb
rm -f "$PSTAT"; STUB_MARKERS="$(markers 2 40)" pcol
STUB_MARKERS="" STUB_RCLONE_RC=124 pcol
expect "timeout keeps the last markers" 0 "OK - Weekly-1 3/3 fresh" no -- chk "$PB"
grep -q 'lastfail=timeout' "$PSTAT" && { echo "  PASS: timeout is recorded as lastfail"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: no lastfail=timeout in status"; FAIL=$((FAIL + 1)); }
rm -f "$PSTAT"; STUB_MARKERS="$(markers 2 40)" pcol; age_file "$PSTAT" 1500
expect "status past REFRESH is still judged" 0 "OK - Weekly-1 3/3" any -- chk "$PB"
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
echo "$*" >> "${STUB_ARGS:-/dev/null}"
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

# --- in-flight guard (RT #1566) -------------------------------------------
# A weekly Servers run moves ~15 GiB in ~144k files over ~10 hours, so for most
# of Saturday the destination is half-written and a not-yet-uploaded dump looks
# exactly like a deleted one. Reporting those as MISSING is what made this check
# cry CRITICAL every week until it was acknowledged into silence.
PBS_UP='[{"Names":["/pbs-server-weekly"],"Image":"pbs"}]'
PBS_MONTHLY='[{"Names":["/pbs-server-monthly-2"]}]'
PBS_PERSONAL='[{"Names":["/pbs-personal-weekly"]}]'
PBS_NONE='[{"Names":["/mcp-grafana"]},{"Names":["/proxy.crunchtools.com"]}]'

STUB_GONE=rt4.sql STUB_SOCK="$PBS_UP" \
    expect "a run is uploading: not-yet-there is UNCHECKED, not MISSING" 3 "^BACKUPS UNKNOWN - rt-db: upload in progress" any -- bf
# Container names differ per rotation (pbs-server-weekly vs pbs-server-monthly-2),
# so the guard matches the prefix and a new rotation inherits it.
STUB_GONE=rt4.sql STUB_SOCK="$PBS_MONTHLY" \
    expect "guard matches any pbs-server-* name shape" 3 "^BACKUPS UNKNOWN - rt-db: upload in progress" any -- bf
# Mode isolation: a personal run says nothing about the servers destination.
STUB_GONE=rt4.sql STUB_SOCK="$PBS_PERSONAL" \
    expect "a personal run does not excuse a missing server dump" 2 "^BACKUPS CRITICAL - rt-db: MISSING" any -- bf
STUB_GONE=rt4.sql STUB_SOCK="$PBS_NONE" \
    expect "nothing running: still MISSING" 2 "^BACKUPS CRITICAL - rt-db: MISSING" any -- bf
# A read that FAILED must not masquerade as a guard that answered "no run".
# Hiding a backup that is really gone is worse than showing a false CRITICAL.
STUB_GONE=rt4.sql STUB_SOCK_RC=7 \
    expect "unreadable podman socket does not suppress MISSING" 2 "^BACKUPS CRITICAL - rt-db: MISSING" any -- bf
STUB_GONE=rt4.sql STUB_SOCK="" \
    expect "empty podman answer does not suppress MISSING" 2 "^BACKUPS CRITICAL - rt-db: MISSING" any -- bf
# With a previous real answer on file the collector substitutes it, so a run in
# flight shows last week's result rather than a gap.
rm -f "$BSTAT"; scol                                   # one clean run: rt-db ok
STUB_GONE=rt4.sql STUB_SOCK="$PBS_UP" scol             # now "missing" while uploading
expect "in-flight keeps the last real answer" 0 "^BACKUPS OK - Weekly-1 15/15 fresh" any -- chk "$BF"
T0=$SECONDS
STUB_SLOW=Backups/Servers PROBE_T=2 BUDGET=3 expect "exhausted deadline leaves sentinels UNCHECKED" 3 "^BACKUPS UNKNOWN - [a-z0-9-]+: TIMEOUT .*, 19 unchecked;.*UNCHECKED \\(out of time\\)" any -- bf
within 4 "exhausted deadline does not overrun"
# The listed path follows the host: gloval judged lotor's frozen rotations (RT #1546).
rm -f "$BSTAT"; : > "$STUB_CALLS"; HOST_FQDN=gloval.test RCLONE="$BSTUBS/rclone" CONF=/dev/null "$COL" servers
if [ "$(grep -c '^pcloud:Backups/Servers/gloval.test/' "$STUB_CALLS")" = 19 ]; then echo "  PASS: every listing is under the host's own FQDN"; PASS=$((PASS + 1))
else echo "  FAIL: listings not under HOST_FQDN: $(grep -v '^pcloud:Backups/Servers/gloval.test/' "$STUB_CALLS" | head -1)"; FAIL=$((FAIL + 1)); fi
# A live SQLite's -shm/-wal is its newest file; directory sentinels must skip them.
STUB_ARGS="$BSTUBS/args"; export STUB_ARGS; : > "$STUB_ARGS"; rm -f "$BSTAT"; scol; unset STUB_ARGS
if grep 'takeda.crunchtools.com/data$' "$BSTUBS/args" | grep -qF -- "--filter - *-wal --filter - *-shm --filter - *-journal --filter + *.db --filter + *.sqlite* --filter - **"; then
    echo "  PASS: directory sentinels filter out SQLite sidecars before *.db, in order"; PASS=$((PASS + 1))
else echo "  FAIL: directory sentinel filters: $(grep 'takeda' "$BSTUBS/args" | head -1)"; FAIL=$((FAIL + 1)); fi
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

echo "=== check_service_running ==="
# systemctl stub: is-system-running prints $STUB_SYSTEM; show prints the four
# properties from $STUB_ACTIVE / $STUB_SUB / $STUB_RESTARTS.
RSTUBS="$(mktemp -d)"
cat > "$RSTUBS/systemctl" <<'STUB'
#!/bin/bash
case "$1" in
    is-system-running) echo "${STUB_SYSTEM-running}"; exit 0 ;;
    show)
        [ -n "${STUB_ACTIVE-x}" ] || exit 0
        echo "ActiveState=${STUB_ACTIVE-active}"
        echo "SubState=${STUB_SUB-running}"
        echo "NRestarts=${STUB_RESTARTS-3}"
        echo "ActiveEnterTimestamp=Wed 2026-11-04 12:33:57 EST" ;;
esac
STUB
chmod +x "$RSTUBS/systemctl"
SR="$LIBEXEC/check_service_running.sh"
sr() { PATH="$RSTUBS:$PATH" "$SR" "$@"; }
expect "running is OK" 0 "^OK - r.service running since .*3 restarts \| restarts=3$" any -- sr r.service
STUB_ACTIVE=activating STUB_SUB=start expect "starting is WARNING" 1 "^WARNING - r.service is activating \(start\)" any -- sr r.service
STUB_ACTIVE=activating STUB_SUB=auto-restart STUB_RESTARTS=40 expect "restart loop is CRITICAL" 2 "^CRITICAL - r.service is activating \(auto-restart\), 40 restarts" any -- sr r.service
STUB_ACTIVE=failed STUB_SUB=failed expect "failed is CRITICAL" 2 "^CRITICAL - r.service is failed" any -- sr r.service
STUB_ACTIVE=inactive STUB_SUB=dead expect "stopped is CRITICAL" 2 "^CRITICAL - r.service is inactive" any -- sr r.service
STUB_SYSTEM=offline expect "no host systemd is UNKNOWN" 3 "^UNKNOWN .*no reachable system manager" any -- sr r.service
STUB_ACTIVE="" expect "unreadable state is UNKNOWN" 3 "^UNKNOWN - cannot read state of r.service" any -- sr r.service
expect "missing arg is UNKNOWN" 3 "^UNKNOWN - usage" any -- sr
expect "bad unit name rejected" 3 "^UNKNOWN - invalid unit" any -- sr 'x;rm.service'
expect "non-service unit rejected" 3 "^UNKNOWN - invalid unit" any -- sr r.socket
rm -rf "$RSTUBS"

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

echo "=== deploy-drift-collect + check_deploy_drift ==="
# The collector greps fields out of the socket JSON, so one stub body serves
# both the container list (Id) and the per-container inspect (the rest).
DD="$LIBEXEC/check_deploy_drift.sh"
DDC="$LIBEXEC/deploy-drift-collect.sh"
DDSTATE="$(mktemp -d)"
DDSTAT="$DDSTATE/deploy-drift.status"
cat > "$STUBS/kick" <<'STUB'
#!/bin/bash
echo "$*" > "$STUB_EXEC_MARK"
STUB
chmod +x "$STUBS/kick"
ID=$(printf 'a%.0s' $(seq 64))
OLD_TS=$(( $(date +%s) - 40 * 3600 ))
ctr() { # <image-ref> <autoupdate> <digest> [deploy-marker]
    printf '{"Id":"%s","Name":"svc","ImageName":"%s","ImageDigest":"%s","Config":{"Labels":{"io.containers.autoupdate":"%s","io.crunchtools.deploy":"%s"}}}' \
        "$ID" "$1" "$3" "$2" "${4:-}"
}
quay() { printf '{"tags":[{"name":"latest","manifest_digest":"%s","start_ts":%s}]}' "$1" "$2"; }
# ddcol: one collector run; ddchk: judge its file; dd: both, from scratch
ddcol() { STATE_DIR="$DDSTATE" "$DDC"; }
ddchk() { STATE_DIR="$DDSTATE" EXEC="$STUBS/kick" COLLECT=/collector "$DD" "$@"; }
dd() { rm -f "$DDSTAT"; ddcol; ddchk "$@"; }
LATEST=quay.io/crunchtools/svc:latest
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:aa "$OLD_TS") \
    expect "running digest matches Quay is OK" 0 "^DEPLOY DRIFT OK - 1/1 .*collected_age=" no -- dd
STUB_SOCK=$(ctr $LATEST "" sha256:aa) \
    expect "no autoupdate label is unmanaged" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 1 unmanaged, 0 stale, 0 contested\. unmanaged \(no autoupdate label\): svc" no -- dd
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:bb "$OLD_TS") \
    expect "digest behind Quay past grace is stale" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 0 unmanaged, 1 stale, 0 contested" no -- dd
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:bb "$(date +%s)") \
    expect "digest behind Quay inside grace is OK" 0 "^DEPLOY DRIFT OK - 1/1 " no -- dd
expect "the grace is the plugin argument, applied at judging time" 1 "^DEPLOY DRIFT WARNING - .*1 stale" no -- ddchk 0
STUB_SOCK=$(ctr quay.io/crunchtools/svc@sha256:aa "" sha256:aa) \
    expect "digest pin is counted, not drift" 0 "^DEPLOY DRIFT OK - .*pinned=1" no -- dd
STUB_SOCK=$(ctr ghcr.io/other/svc:latest "" sha256:aa) \
    expect "third-party image is ignored" 0 "^DEPLOY DRIFT OK - 0/0 " no -- dd
STUB_SOCK=$(ctr quay.io/crunchtools/pbs:latest "" sha256:aa) \
    expect "one-shot pbs backup job is ignored" 0 "^DEPLOY DRIFT OK - 0/0 " no -- dd
STUB_SOCK=$(ctr quay.io/crunchtools/developer:latest "" sha256:aa) \
    expect "a developer seat with no label is ignored, not unmanaged" 0 "^DEPLOY DRIFT OK - 0/0 " no -- dd
# The deploy robot's own registry. A marked service deliberately carries no
# autoupdate label -- it is deployed by ticket, verified, and rolled back on
# failure -- so "behind the tag" is normal for it and reporting it as unmanaged
# would leave a WARNING nobody could ever clear. Quay is not even asked, which
# is why no STUB_DIRECT is set here.
STUB_SOCK=$(ctr $LATEST "" sha256:aa deployer) \
    expect "a deployer-managed service is not unmanaged" 0 "^DEPLOY DRIFT OK - 0/0 containers run the image their tag points at, 1 deployed by ticket .*deployer=1" no -- dd
# And it must not be let through on the image name: the marker is what counts,
# so an unmarked container with the same image is still unmanaged.
STUB_SOCK=$(ctr $LATEST "" sha256:aa) \
    expect "the same image without the marker is still unmanaged" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 1 unmanaged" no -- dd
# Both mechanisms owning one service is the onboarding mistake, and it is drift
# rather than something to resolve silently in favour of either one.
STUB_SOCK=$(ctr $LATEST registry sha256:aa deployer) \
    expect "both markers is contested, not deployer-managed" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 0 unmanaged, 0 stale, 1 contested\\. contested \\(deployer marker AND autoupdate=registry\\): svc" no -- dd
# A marker this check has never heard of is not a free pass out of auto-update.
STUB_SOCK=$(ctr $LATEST "" sha256:aa somethingelse) \
    expect "an unrecognised marker value is still unmanaged" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 1 unmanaged" no -- dd
# RETENTION FOR THE TWO NEW KINDS. A marked container never asks Quay, so its
# only route to UNKNOWN is the INSPECT failing -- and when inspect fails the
# labels cannot be read, so the previous answer is the only thing that stops a
# deployer-managed service reading as unreadable every time the socket hiccups.
# The listing still succeeds in both of these: the token matches only the
# per-container URL.
STUB_SOCK=$(ctr $LATEST "" sha256:aa deployer) dd >/dev/null
STUB_SOCK=$(ctr $LATEST "" sha256:aa deployer) STUB_SOCK_TOKEN=aaaa STUB_SOCK_ALT_RC=22 ddcol
expect "an unreadable inspect keeps a DEPLOYER answer" 0 "^DEPLOY DRIFT OK - 0/0 .*deployer=1" no -- ddchk
STUB_SOCK=$(ctr $LATEST registry sha256:aa deployer) dd >/dev/null
STUB_SOCK=$(ctr $LATEST registry sha256:aa deployer) STUB_SOCK_TOKEN=aaaa STUB_SOCK_ALT_RC=22 ddcol
expect "an unreadable inspect keeps a CONTESTED answer" 1 "^DEPLOY DRIFT WARNING - .*1 contested" no -- ddchk
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT_RC=22 \
    expect "first-ever unreadable Quay is UNKNOWN, never OK" 3 "^DEPLOY DRIFT UNKNOWN - 1/1 containers could not be checked\. unreadable: svc" no -- dd
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:bb "$OLD_TS") dd >/dev/null
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT_RC=22 ddcol
expect "an unreadable Quay keeps the last answer" 1 "^DEPLOY DRIFT WARNING - 1/1 containers drifted: 0 unmanaged, 1 stale, 0 contested" no -- ddchk
sed -i -E "/item=/s/seen=[0-9]+/seen=$(( $(date +%s) - 11000 ))/" "$DDSTAT"
expect "an answer older than STALE counts as unreadable" 3 "^DEPLOY DRIFT UNKNOWN - 1/1 containers could not be checked\. unreadable: svc\\(stale\\)" no -- ddchk
STUB_SOCK_RC=7 expect "socket unreadable is UNKNOWN" 3 "^DEPLOY DRIFT UNKNOWN - cannot list containers" no -- dd
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:aa "$OLD_TS") dd >/dev/null
STUB_SOCK_RC=7 ddcol 2>/dev/null
expect "a failed listing keeps the previous file" 0 "^DEPLOY DRIFT OK - 1/1 " no -- ddchk
STUB_SOCK='[]' expect "no running containers is UNKNOWN" 3 "^DEPLOY DRIFT UNKNOWN - podman listed no running containers" no -- dd
expect "non-numeric grace is UNKNOWN" 3 "^DEPLOY DRIFT UNKNOWN - grace_hours" no -- ddchk soon
STUB_SOCK=$(ctr $LATEST registry sha256:aa) STUB_DIRECT=$(quay sha256:aa "$OLD_TS") ddcol
age_ddstat() { local t=$(( $(date +%s) - $1 )); sed -i -E "s/generated=[0-9]+/generated=$t/; s/seen=[0-9]+/seen=$t/g" "$DDSTAT"; }
age_ddstat 2000
expect "status past REFRESH is still judged and starts the collector" 0 "^DEPLOY DRIFT OK - 1/1 " yes -- ddchk
age_ddstat 11000
expect "status past STALE is UNKNOWN collector stale" 3 "^DEPLOY DRIFT UNKNOWN - collector stale: last collection 3h" yes -- ddchk
rm -f "$DDSTAT"
expect "missing status is UNKNOWN and starts the collector" 3 "^DEPLOY DRIFT UNKNOWN - collector stale: no status file .*collector started" yes -- ddchk
grep -q -- '--detach nagios-agent-ctr.crunchtools.com /collector' "$STUB_EXEC_MARK" \
    && { echo "  PASS: kick is a detached exec in the ctr agent"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: kick args: $(cat "$STUB_EXEC_MARK")"; FAIL=$((FAIL + 1)); }
rm -rf "$DDSTATE"

echo "=== config-drift-repos-collect + check_config_drift ==="
# Real git throughout: a /srv-shaped repo for the fingerprint (run through an
# exec stub that drops the container name), and rival repos served from a
# file:// "GitHub".
CD="$LIBEXEC/check_config_drift.sh"
CDC="$LIBEXEC/config-drift-repos-collect.sh"
CW="$(mktemp -d)"
CDSTATE="$CW/state"; CDSTAT="$CDSTATE/config-drift.status"; mkdir -p "$CDSTATE"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cat > "$CW/fpexec" <<'STUB'
#!/bin/bash
[ -n "${STUB_FP_FAIL:-}" ] && exit 3
[ -n "${STUB_FP_SLOW:-}" ] && exec sleep 30
shift; exec "$@"
STUB
chmod +x "$CW/fpexec"
# /srv: svc/config/app.conf deployed and pushed.
git init -q "$CW/srv"; mkdir -p "$CW/srv/svc/config"
echo 'listen 80' > "$CW/srv/svc/config/app.conf"
git -C "$CW/srv" add -A; git -C "$CW/srv" commit -qm srv
git -C "$CW/srv" update-ref refs/remotes/origin/master HEAD
rival() { # <content of deploy/app.conf in the rival repo>
    rm -rf "$CW/gh/org/rival"; git init -q "$CW/gh/org/rival"; mkdir -p "$CW/gh/org/rival/deploy"
    echo "$1" > "$CW/gh/org/rival/deploy/app.conf"
    git -C "$CW/gh/org/rival" add -A; git -C "$CW/gh/org/rival" commit -qm r
}
echo 'svc rival' > "$CW/sources.conf"
cdcol() {
    STATE_DIR="$CDSTATE" EXEC="$CW/fpexec" FINGERPRINT="$LIBEXEC/config-drift-collect.sh" \
        CONFIG_DRIFT_REPO="$CW/srv" CONFIG_DRIFT_CONF="$CW/sources.conf" \
        CONFIG_DRIFT_GIT_HOST="file://$CW/gh" CONFIG_DRIFT_ORG=org "$CDC" 2>/dev/null
}
cdchk() { STATE_DIR="$CDSTATE" EXEC="$CW/kick" COLLECT=/collector CONFIG_DRIFT_CONF="$CW/sources.conf" "$CD"; }
cd_() { rm -f "$CDSTAT"; cdcol; cdchk; }
cp "$STUBS/kick" "$CW/kick"
rival 'listen 80'
expect "rival copy that matches is OK (duplicate)" 0 "^CONFIG DRIFT OK - 1 deployed config file\\(s\\), none with a divergent second git home \\|.*duplicate=1;.*collected_age=" no -- cd_
rival 'listen 8080'
expect "divergent rival copy is WARNING" 1 "^CONFIG DRIFT WARNING - 1/1 deployed config file\\(s\\) have a divergent second git home\\. divergent: rival/deploy/app.conf" no -- cd_
CONFIG_DRIFT_MAX_DIVERGENT=1 expect "the ratchet stays in the plugin" 0 "^CONFIG DRIFT OK - 1 divergent, at or under the ratchet of 1" no -- cdchk
# A VCS ignore list is not configuration. A repo's .gitignore names build
# output and editor droppings; the one beside a service's config names runtime
# state that must not be committed. They describe different trees and are MEANT
# to differ, so comparing them reports drift that can never be resolved -- and
# a WARNING nobody can clear teaches the fleet to ignore the check.
#
# divergent=0 is what proves the skip, not the file count: the deployed tally
# comes from the fingerprint collector and still counts .gitignore as a file
# present on disk, which changes no verdict. Without the skip this same
# fixture reports divergent=1 and goes WARNING, because the two ignore lists
# are written to differ.
rival 'listen 80'
printf 'build/\n' > "$CW/gh/org/rival/.gitignore"
git -C "$CW/gh/org/rival" add -A; git -C "$CW/gh/org/rival" commit -qm ignore
printf '*.sock\n' > "$CW/srv/svc/config/.gitignore"
git -C "$CW/srv" add -A; git -C "$CW/srv" commit -qm srvignore
git -C "$CW/srv" update-ref refs/remotes/origin/master HEAD
expect ".gitignore is not configuration and is never compared" 0 "^CONFIG DRIFT OK - 2 deployed config file\\(s\\), none with a divergent second git home \\|.*divergent=0;" no -- cd_
rm -f "$CW/srv/svc/config/.gitignore"
git -C "$CW/srv" add -A; git -C "$CW/srv" commit -qm rmignore
git -C "$CW/srv" update-ref refs/remotes/origin/master HEAD
rival 'listen 8080'
echo 'listen 81' > "$CW/srv/svc/config/app.conf"
expect "unpublished AND divergent is CRITICAL" 2 "^CONFIG DRIFT CRITICAL - 1 deployed file\\(s\\) differ from origin/master AND from a rival git home" no -- cd_
echo 'listen 80' > "$CW/srv/svc/config/app.conf"
mv "$CW/gh/org/rival" "$CW/gh/org/gone"
cdcol
expect "a failed clone keeps the last good tree" 1 "^CONFIG DRIFT WARNING - 1/1 .*divergent: rival/deploy/app.conf" no -- cdchk
printf '0\n' > "$CDSTATE/config-drift-repos/rival.seen"; cdcol
expect "a repo last read past STALE is unreadable, its findings dropped" 3 "^CONFIG DRIFT UNKNOWN - 1 project repo\\(s\\) could not be read, nothing to compare against\\. unreadable: rival" no -- cdchk
rm -rf "$CDSTATE/config-drift-repos"
expect "a repo never read is UNKNOWN" 3 "^CONFIG DRIFT UNKNOWN - 1 project repo\\(s\\) could not be read" no -- cd_
mv "$CW/gh/org/gone" "$CW/gh/org/rival"
printf 'svc rival\nother none\n' > "$CW/sources.conf"; mkdir -p "$CW/srv/new/config"; echo x > "$CW/srv/new/config/x.conf"
git -C "$CW/srv" add -A; git -C "$CW/srv" commit -qm new; git -C "$CW/srv" update-ref refs/remotes/origin/master HEAD
expect "an unmapped service is named in the headline" 1 "^CONFIG DRIFT WARNING - 1/2 .*, 1 service\\(s\\) UNMAPPED\\. .*unmapped: new" no -- cd_
cdcol; STUB_FP_FAIL=1 cdcol
expect "a failed fingerprint exec keeps the previous file" 1 "^CONFIG DRIFT WARNING - 1/2 " no -- cdchk
rm -f "$CDSTAT"; STUB_FP_FAIL=1 cdcol
expect "a failed fingerprint with no previous file says why" 3 "^CONFIG DRIFT UNKNOWN - collector reported: fingerprint exec in nagios-agent.crunchtools.com exited 3" no -- cdchk
T0=$SECONDS
rm -f "$CDSTAT"; STUB_FP_SLOW=1 CONFIG_DRIFT_FP_TIMEOUT=1 cdcol
ok_if "a hung fingerprint exec stays inside its timeout" [ $((SECONDS - T0)) -le 3 ]
expect "a timed-out fingerprint with no previous file says why" 3 "^CONFIG DRIFT UNKNOWN - collector reported: fingerprint exec in nagios-agent.crunchtools.com exited 124" no -- cdchk
rm -f "$CDSTAT"; STATE_DIR="$CDSTATE" CONFIG_DRIFT_CONF=/nonexistent "$CDC"
expect "unreadable source map is UNKNOWN" 3 "^CONFIG DRIFT UNKNOWN - cannot read source map" no -- cdchk
cdcol; sed -i -E "s/generated=[0-9]+/generated=$(( $(date +%s) - 2000 ))/" "$CDSTAT"
expect "status past REFRESH is still judged and starts the collector" 1 "^CONFIG DRIFT WARNING" yes -- cdchk
sed -i -E "s/generated=[0-9]+/generated=$(( $(date +%s) - 11000 ))/" "$CDSTAT"
expect "status past STALE is UNKNOWN collector stale" 3 "^CONFIG DRIFT UNKNOWN - collector stale: last collection 3h" yes -- cdchk
rm -f "$CDSTAT"
expect "missing status is UNKNOWN and starts the collector" 3 "^CONFIG DRIFT UNKNOWN - collector stale: no status file .*collector started" yes -- cdchk
grep -q -- '--detach nagios-agent-ctr.crunchtools.com /collector' "$STUB_EXEC_MARK" \
    && { echo "  PASS: kick is a detached exec in the ctr agent"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: kick args: $(cat "$STUB_EXEC_MARK")"; FAIL=$((FAIL + 1)); }
rm -rf "$CW"

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

echo "=== check_selinux_drift ==="
SD="$LIBEXEC/check_selinux_drift.sh"
sd() { EXEC="$STUBS/podman_exec.sh" "$SD"; }
sdout() { printf 'SELINUXDRIFT file=present\nSELINUXDRIFT live_only=%s\nSELINUXDRIFT file_only=%s\nSELINUXDRIFT list=%s\nSELINUXDRIFT end=1\n' "$1" "$2" "${3:-}"; }
STUB_EXEC="$(sdout 0 0)" expect "matching SELinux state is OK" 0 "^SELINUX DRIFT OK - live customizations match /srv" yes -- sd
STUB_EXEC="$(sdout 1 1 'boolean virt_use_nfs')" expect "flipped boolean is WARNING and named" 1 "^SELINUX DRIFT WARNING - 1 live setting\\(s\\) not in /srv, 1 in /srv not live \\(boolean virt_use_nfs\\)" yes -- sd
STUB_EXEC=$'SELINUXDRIFT file=missing\nSELINUXDRIFT end=1' expect "missing export file is WARNING" 1 "^SELINUX DRIFT WARNING - .*local.semanage is missing" yes -- sd
STUB_EXEC=$'SELINUXDRIFT error=semanage export failed\nSELINUXDRIFT end=1' expect "collector error is UNKNOWN" 3 "^SELINUX DRIFT UNKNOWN - collector reported: semanage export failed" yes -- sd
STUB_EXEC="SELINUXDRIFT file=present" expect "truncated output is UNKNOWN" 3 "^SELINUX DRIFT UNKNOWN - collector output truncated" yes -- sd
STUB_EXEC_RC=125 expect "exec failure is UNKNOWN" 3 "^SELINUX DRIFT UNKNOWN - collector exec" yes -- sd
STUB_EXEC="$(sdout x 0)" expect "non-numeric count is UNKNOWN" 3 "^SELINUX DRIFT UNKNOWN - collector returned a non-numeric count" yes -- sd
STUB_EXEC=$'SELINUXDRIFT file=present\nSELINUXDRIFT file_only=0\nSELINUXDRIFT end=1' expect "missing count is UNKNOWN" 3 "^SELINUX DRIFT UNKNOWN - collector returned a non-numeric count" yes -- sd

echo "=== selinux-drift-collect ==="
SX="$(mktemp -d)"
cat > "$SX/semanage" <<'STUB'
#!/bin/bash
[ -n "${STUB_SEMANAGE_FAIL:-}" ] && exit 1
printf 'boolean -D\nboolean -m -1 httpd_can_network_connect\nboolean -m -%s virt_use_nfs\nport -a -t ssh_port_t -r '"'"'s0'"'"' -p tcp %s\nfcontext -a -f a -t %s -r '"'"'s0'"'"' '"'"'/srv/x/bin(/.*)?'"'"'\n' "${STUB_NFS:-1}" "${STUB_PORT:-22422}" "${STUB_FCTX:-bin_t}"
STUB
chmod +x "$SX/semanage"
printf 'boolean -D\nboolean -m -1 httpd_can_network_connect\nboolean -m -1 virt_use_nfs\nport -a -t ssh_port_t -r '"'"'s0'"'"' -p tcp 22422\nfcontext -a -f a -t bin_t -r '"'"'s0'"'"' '"'"'/srv/x/bin(/.*)?'"'"'\n' > "$SX/local.semanage"
sx() { FILE="$SX/local.semanage" SEMANAGE="$SX/semanage" "$LIBEXEC/selinux-drift-collect.sh"; }
OUT=$(sx)
ok_if "collector: identical state counts 0/0" grep -qz "live_only=0.*file_only=0.*end=1" <<< "$OUT"
OUT=$(STUB_NFS=0 sx)
ok_if "collector: flipped boolean counts 1/1 and names it" grep -qz "live_only=1.*file_only=1.*list=boolean virt_use_nfs.*end=1" <<< "$OUT"
OUT=$(STUB_PORT=2222 sx)
ok_if "collector: added port is live-only and named" grep -qz "live_only=1.*file_only=1.*list=port 2222,port 22422.*end=1" <<< "$OUT"
OUT=$(STUB_FCTX=httpd_sys_content_t sx)
ok_if "collector: changed file-context rule is named by path" grep -qz "live_only=1.*file_only=1.*list=fcontext /srv/x/bin(/\.\*)?.*end=1" <<< "$OUT"
: > "$SX/empty"
OUT=$(FILE="$SX/empty" SEMANAGE="$SX/semanage" "$LIBEXEC/selinux-drift-collect.sh")
ok_if "collector: empty file counts only live settings, no blank record" grep -qz "live_only=4.*file_only=0.*end=1" <<< "$OUT"
OUT=$(STUB_SEMANAGE_FAIL=1 sx)
ok_if "collector: semanage failure reports an error" grep -q "SELINUXDRIFT error=semanage export failed" <<< "$OUT"
OUT=$(FILE="$SX/absent" SEMANAGE="$SX/semanage" "$LIBEXEC/selinux-drift-collect.sh")
ok_if "collector: missing file reported" grep -q "SELINUXDRIFT file=missing" <<< "$OUT"
rm -rf "$SX"

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
[ -n "${STUB_GIT_SLOW_REPO:-}" ] && [[ "${!#}" == */"$STUB_GIT_SLOW_REPO" ]] && exec sleep 30
[ -n "${STUB_TAG:-}" ] && printf 'deadbeef\trefs/tags/v%s\n' "$STUB_TAG"
exit 0
STUB
cat > "$GSTUBS/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        --unix-socket) printf '%s' "${STUB_LOCAL:-[]}"; exit 0 ;;
        */tag/*)
            [ -n "${STUB_QUAY_FAIL:-}" ] && exit 22
            # STUB_QUAY_HAS set: answer specificTag lookups like Quay, from
            # that list of tag names, logging each name asked for.
            if [ -n "${STUB_QUAY_HAS+x}" ]; then
                t=${a##*specificTag=}
                echo "$t" >> "$STUB_QUAY_LOG"
                [ -n "${STUB_QUAY_FAIL_V:-}" ] && [ "${t#v}" != "$t" ] && exit 22
                case " $STUB_QUAY_HAS " in
                    *" $t "*) printf '{"tags": [{"name": "%s", "start_ts": 1}]}' "$t" ;;
                    *) printf '{"tags": [], "page": 1, "has_additional": false}' ;;
                esac
                exit 0
            fi
            printf '%s' "${STUB_QUAY:-}"; exit 0 ;;
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
# Quay is asked for the release tag by name, so tags pushed after it (rotv
# tags every commit) can't page it out of view.
export STUB_QUAY_LOG="$GSTUBS/quay.log"
rm -f "$STUB_QUAY_LOG"; STUB_TAG=1.2.0 STUB_QUAY_HAS="1.2.0" STUB_GHCR="$GH_HAS" \
    expect "the release tag is found by name" 0 "^REGISTRY DRIFT OK - 1/1 images carry" any -- rd
ok_if "a found bare tag needs one Quay request" [ "$(cat "$STUB_QUAY_LOG")" = "1.2.0" ]
rm -f "$STUB_QUAY_LOG"; STUB_TAG=1.2.0 STUB_QUAY_HAS="v1.2.0" STUB_GHCR="$GH_HAS" \
    expect "a v-prefixed release tag is found" 0 "^REGISTRY DRIFT OK - 1/1 images carry" any -- rd
ok_if "the v-prefixed tag is asked for after the bare one" [ "$(tr '\n' ' ' < "$STUB_QUAY_LOG")" = "1.2.0 v1.2.0 " ]
STUB_TAG=1.2.0 STUB_QUAY_HAS="" STUB_GHCR="$GH_HAS" \
    expect "a tag Quay has under neither name is missing" 1 "^REGISTRY DRIFT WARNING - .*missing: svc:1.2.0\\[quay\\]" any -- rd
STUB_TAG=1.2.0 STUB_QUAY_HAS="" STUB_QUAY_FAIL_V=1 STUB_GHCR="$GH_HAS" \
    expect "a failed v-prefixed lookup is UNKNOWN, not missing" 3 "^REGISTRY DRIFT UNKNOWN - 1/1 images could not be checked. unreadable: svc\\(quay\\)" any -- rd
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
# Answers are matched to images by name: a finished image keeps its answer
# beside one the budget cut off, and a name the conf rule rejects is dropped.
printf 'svc svc\nslow slow\nbad bad/x\n' > "$GSTUBS/images.conf"
rm -f "$RDSTAT"; STUB_TAG=1.2.0 STUB_QUAY="$(quayj $((T - 100)))" STUB_GHCR="$GH_HAS" STUB_GIT_SLOW_REPO=slow BUDGET=2 REGISTRY_DRIFT_TIMEOUT=3 rdcol
expect "answers are matched by image, missing ones UNKNOWN" 3 "^REGISTRY DRIFT UNKNOWN - 1/2 images could not be checked. unreadable: slow\\(budget\\)" no -- rdchk
ok_if "finished image keeps its own answer" grep -q '^RDRIFT item=svc seen=[0-9]* kind=CLEAN$' "$RDSTAT"
ok_if "an image name the conf rule rejects is not recorded" bash -c '! grep -q "item=bad" "$0"' "$RDSTAT"
echo "svc svc" > "$GSTUBS/images.conf"
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
    # EXCLUDED_SCOPES: an environment we cannot be in stays OK even though
    # Cloudflare filed it under a component we do depend on. The first is the
    # verbatim incident that paged us for five hours on 2026-11-08.
    FEDRAMP=$(cf_incident "Fedramp Customers have Delayed Purges" minor "CDN Cache Purge")
    CHINA=$(cf_incident "China Network egress degraded" major "CDN/Cache")
    STUB_INC="{\"incidents\":[$FEDRAMP]}" \
        expect "FedRAMP-scoped purge delay stays OK" 0 "^OK - No incidents affecting our components .*1 unrelated: Fedramp Customers have Delayed Purges \\(out of scope\\)" no -- cfg
    STUB_INC="{\"incidents\":[$CHINA]}" \
        expect "China Network stays OK even at major impact" 0 "^OK - No incidents affecting our components .*out of scope" no -- cfg
    STUB_INC="{\"incidents\":[$FEDRAMP,$CDN]}" \
        expect "an out-of-scope incident does not mask a real one" 1 "^WARNING - Cloudflare: Elevated cache errors .*1 unrelated" no -- cfg
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
printf '# key container credential label\npersonal ctr-a /cred/alice@example.com.json alice@example.com\nwork ctr-b /cred/bob@example.org.json bob@example.org\nbroken ctr;x /cred/c.json carol@example.net\n' > "$RSTUBS/accounts.conf"
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
# Regression (7.1.0): credential paths named for the account carry '@'; the
# collector skipped them silently and both accounts sat at "not collected yet".
STUB_OAUTH='OAUTH|200|3599' expect "an '@' in the credential path is collected" 0 "^OK - bob@example.org: refresh token valid" no -- go work
expect "a rejected conf line is reported, not skipped" 3 "^UNKNOWN - carol@example.net: google-accounts.conf line rejected" no -- gchk broken
expect "unknown account key is UNKNOWN" 3 "^UNKNOWN - account key 'nobody' not found" no -- gchk nobody
rm -rf "$RSTATE" "$RSTUBS"

echo "=== check_container_postgres ==="
PG="$LIBEXEC/check_container_postgres.sh"
STUB_EXEC='exec: "pg_isready": executable file not found in $PATH' STUB_EXEC_RC=127 \
    expect "pg_isready missing is UNKNOWN, not an outage" 3 "^UNKNOWN - pg_isready missing from image ctr$" yes -- "$PG" ctr
STUB_EXEC='localhost:5432 - no response' STUB_EXEC_RC=2 \
    expect "no response is still CRITICAL" 2 "^CRITICAL - PostgreSQL in ctr not accepting connections" yes -- "$PG" ctr
STUB_EXEC='7' STUB_EXEC_RC=0 expect "accepting with few connections is OK" 0 "^OK - PostgreSQL in ctr: 7 active" yes -- "$PG" ctr

echo "=== podman_exec.sh request body ==="
# podman_exec.sh hand-builds the exec request as JSON. A literal newline or
# tab in an argument used to go straight into the string, making the body
# invalid; the API refused the exec and the only symptom was
# "Cannot create exec", which reads like a container problem rather than a
# quoting one (RT#1548). This asserts the body parses. It targets the request
# body and not a plugin, because the plugin tests stub podman_exec.sh out and
# never look at the arguments, which is why this went unnoticed.
PESTUBS="$(mktemp -d)"
# Capture the exec CREATE body only. podman_exec.sh also POSTs to
# .../exec/<id>/start, whose body is a fixed {"Detach":false} and always
# parses — capturing that instead is how an earlier version of this test
# passed against the very escaper it was meant to catch.
cat > "$PESTUBS/curl" <<'STUB'
#!/bin/bash
url=""; body=""; prev=""
for a in "$@"; do
    [ "$prev" = "-d" ] && body="$a"
    case "$a" in http*) url="$a" ;; esac
    prev="$a"
done
case "$url" in */exec) printf '%s' "$body" > "$PE_BODY" ;; esac
printf '%s' '{"Id":"deadbeef"}'
STUB
chmod +x "$PESTUBS/curl"
for arg in 'plain' 'two
lines' 'tab	with "quote"' 'back\slash' "$(printf 'carriage\rreturn')" "$(printf 'back\bspace form\ffeed')"; do
    PE_BODY="$PESTUBS/body.json" PATH="$PESTUBS:$PATH" \
        "$LIBEXEC/podman_exec.sh" ctr sh -c "$arg" >/dev/null 2>&1
    label=$(printf '%s' "$arg" | tr '\n\t' '..' | head -c 20)
    # Parsing is not enough: an escaper could emit valid JSON having dropped
    # or altered the argument. Assert the decoded Cmd is exactly what went in.
    printf '%s' "$arg" > "$PESTUBS/want.txt"
    # newline="" or python translates a lone CR in the expected value to LF
    # and the comparison fails against a correctly escaped body.
    if python3 -c 'import json,sys
body = json.load(open(sys.argv[1]))
want = open(sys.argv[2], newline="").read()
assert body["Cmd"] == ["sh", "-c", want], body["Cmd"]' "$PESTUBS/body.json" "$PESTUBS/want.txt" 2>/dev/null; then
        echo "  PASS: arguments survive the round trip for $label"; PASS=$((PASS + 1))
    else
        echo "  FAIL: body invalid or arguments altered for: $label"
        cat "$PESTUBS/body.json"; FAIL=$((FAIL + 1))
    fi
done
# A control character JSON cannot name is refused with a message that says
# so, rather than building a body the API rejects as "Cannot create exec".
pe_out=$(PE_BODY="$PESTUBS/body.json" PATH="$PESTUBS:$PATH" \
    "$LIBEXEC/podman_exec.sh" ctr sh -c "$(printf 'bell\007here')" 2>&1); pe_rc=$?
if [ "$pe_rc" = "3" ] && printf '%s' "$pe_out" | grep -q 'unencodable control character'; then
    echo "  PASS: an unencodable control character is refused, not mangled"; PASS=$((PASS + 1))
else
    echo "  FAIL: expected rc=3 and an unencodable-control message, got rc=$pe_rc: $pe_out"; FAIL=$((FAIL + 1))
fi
rm -rf "$PESTUBS"

echo "=== check_container_opendkim ==="
DK="$LIBEXEC/check_container_opendkim.sh"
expect "no container argument is UNKNOWN" 3 "^UNKNOWN - Usage:" no -- "$DK"
STUB_EXEC='ok' STUB_EXEC_RC=0 \
    expect "running and listening is OK" 0 "^OK - opendkim running and listening in ctr" yes -- "$DK" ctr
# A dead signer must be CRITICAL, not a warning: mail keeps flowing unsigned,
# so nothing else will report it.
STUB_EXEC='nopid' STUB_EXEC_RC=0 \
    expect "a dead signer is CRITICAL and says mail is unsigned" 2 "^CRITICAL - opendkim not running in ctr: outbound mail is going out unsigned" yes -- "$DK" ctr
STUB_EXEC='nosocket' STUB_EXEC_RC=0 \
    expect "up but not accepting connections is CRITICAL" 2 "^CRITICAL - opendkim in ctr is not listening on 127.0.0.1:8891" yes -- "$DK" ctr
# An unreachable container is our blind spot, not the signer's fault.
STUB_EXEC='no container with name or ID "ctr"' STUB_EXEC_RC=3 \
    expect "an unreachable container is UNKNOWN, not an outage" 3 "^UNKNOWN - cannot reach ctr:" yes -- "$DK" ctr
STUB_EXEC='something else entirely' STUB_EXEC_RC=0 \
    expect "an unrecognised probe result is UNKNOWN, not OK" 3 "^UNKNOWN - unexpected probe result from ctr" yes -- "$DK" ctr

echo "=== check_container_storage ==="
CS="$LIBEXEC/check_container_storage.sh"
CSD="$(mktemp -d)"
# Per-service stub: the shared podman_exec.sh stub answers every call the same,
# and this check reads four different stores, so "one is down" needs its own.
# It speaks podman_exec.sh's real dialect -- failures are "EXEC_ERROR: ..." on
# stdout with exit 0, which is why the plugin reads the text and not the status.
cat > "$CSD/exec" <<'STUB'
#!/bin/bash
svc=${1%%.*}
var="CS_${svc//-/_}"
val=${!var:-ABSENT}
vol='Local Volumes|7256352906|1'
case "$val" in
    ABSENT) echo "EXEC_ERROR: Cannot create exec in container $1"; exit 0 ;;
    ERROR)  echo "EXEC_ERROR: Get http://d/v5.0.0/libpod/_ping: connection refused"; exit 0 ;;
    JUNK)   echo "not a df table at all"; exit 0 ;;
    VOLFIRST:*) v=${val#VOLFIRST:}
            printf '%s\nImages|%s|%s\nContainers|0|0\n' "$vol" "${v%%:*}" "${v##*:}"; exit 0 ;;
    *)      printf 'Images|%s|%s\nContainers|0|0\n%s\n' "${val%%:*}" "${val##*:}" "$vol"; exit 0 ;;
esac
STUB
chmod +x "$CSD/exec"
cs() { EXEC="$CSD/exec" "$CS" "$@"; }
G=1073741824
# 3 GB of images in each sandbox is 9 GB alerted; the 17 GB runner cache and the
# 7.26 GB volume in every store must stay out of that sum. Plain prefix
# assignments, not env: expect is a shell function.
CS_developer1=$((3*G)):4 CS_developer2=$((3*G)):4 CS_developer3=$((3*G)):4 CS_gha_runner_cached=$((17*G)):30 \
    expect "images under warn are OK, volumes excluded" 0 "^CONTAINER STORAGE OK - sandbox images 9\.0G of 24G" any -- cs
CS_developer1=$((3*G)):4 CS_developer2=$((3*G)):4 CS_developer3=$((3*G)):4 CS_gha_runner_cached=$((17*G)):30 \
    expect "the runner cache is reported but not counted" 0 "gha-runner-cached 17\.0G/30 \(cache, not counted\)" any -- cs
# The Images row is selected by its Type, so podman reordering the table cannot
# make the 7.26 GB volume look like images and trip the thresholds.
CS_developer1=VOLFIRST:$((3*G)):4 CS_developer2=VOLFIRST:$((3*G)):4 CS_developer3=VOLFIRST:$((3*G)):4 \
    expect "a volume row first does not become the image size" 0 "^CONTAINER STORAGE OK - sandbox images 9\.0G of 24G" any -- cs
CS_developer1=$((9*G)):12 CS_developer2=$((9*G)):12 CS_developer3=$((9*G)):12 \
    expect "27G of images is WARNING and names the prune" 1 "^CONTAINER STORAGE WARNING - sandbox images 27\.0G \(warn 24G\), is container-storage-prune running" any -- cs
CS_developer1=$((13*G)):18 CS_developer2=$((13*G)):18 CS_developer3=$((13*G)):18 \
    expect "39G of images is CRITICAL" 2 "^CONTAINER STORAGE CRITICAL - sandbox images 39\.0G \(crit 36G\)" any -- cs
# An absent container is idle, not broken: gha-runner-cached runs --rm with
# Restart=always and is legitimately gone between CI jobs.
CS_developer1=$((3*G)):4 CS_developer3=$((3*G)):4 \
    expect "a sandbox that is idle is named and not fatal" 0 "^CONTAINER STORAGE OK - sandbox images 6\.0G.*idle: developer2 \(not running\), gha-runner-cached \(not running\)" any -- cs
# A dead socket is NOT idle. Saying OK on a store we could not read would be a
# lie, and it is the failure that hides a growing store.
CS_developer1=$((3*G)):4 CS_developer2=ERROR CS_developer3=$((3*G)):4 \
    expect "an exec error is UNKNOWN, not idle" 3 "^CONTAINER STORAGE UNKNOWN - a store could not be read:.*unreadable: developer2 \(exec failed: .*connection refused" any -- cs
CS_developer1=$((3*G)):4 CS_developer2=JUNK CS_developer3=$((3*G)):4 \
    expect "an unparseable df table is UNKNOWN" 3 "^CONTAINER STORAGE UNKNOWN - a store could not be read:.*unreadable: developer2 \(no Images row" any -- cs
expect "no store readable at all is UNKNOWN" 3 "^CONTAINER STORAGE UNKNOWN - no alerted store could be read" any -- cs
CS_developer1=$((3*G)):4 CS_developer2=$((3*G)):4 CS_developer3=$((3*G)):4 \
    expect "thresholds are overridable" 1 "^CONTAINER STORAGE WARNING - sandbox images 9\.0G \(warn 8G\)" any -- cs 8 36
# Naming services replaces the alerted set and clears the context set, so a
# cache named explicitly does count -- the usage text says so.
CS_developer1=$((3*G)):4 CS_gha_runner_cached=$((17*G)):30 \
    expect "an explicit service list replaces both sets" 1 "^CONTAINER STORAGE WARNING - sandbox images 20\.0G \(warn 10G\).*gha-runner-cached 17\.0G/30" any -- cs 10 36 developer1 gha-runner-cached
# `shift 2` with a single argument shifts nothing, so that argument used to fall
# through into the service list and the check watched a service named "30".
CS_developer1=$((3*G)):4 CS_developer2=$((3*G)):4 CS_developer3=$((3*G)):4 \
    expect "a lone threshold argument is not read as a service" 1 "^CONTAINER STORAGE WARNING - sandbox images 9\.0G \(warn 8G\)" any -- cs 8
rm -rf "$CSD"

echo "=== Hermes probes (python unittest) ==="
if UT=$(python3 -m unittest -q "$HERE/test_hermes_probes.py" 2>&1); then
    echo "  PASS: probe unit tests ($(echo "$UT" | grep -o 'Ran [0-9]* tests'))"; PASS=$((PASS + 1))
else
    echo "  FAIL: probe unit tests"; echo "$UT" | tail -20; FAIL=$((FAIL + 1))
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
