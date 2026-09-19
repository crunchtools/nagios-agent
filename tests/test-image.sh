#!/bin/bash
set -euo pipefail

RUNTIME="${RUNTIME:-podman}"
IMAGE="${IMAGE:-nagios-agent:test}"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        [ -n "$output" ] && echo "        $output"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Static tests ==="

check "nrpe binary exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/sbin/nrpe"

check "nrpe config exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -f /etc/nagios/nrpe.cfg"

check "check_load plugin exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/lib64/nagios/plugins/check_load"

check "check_disk plugin exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/lib64/nagios/plugins/check_disk"

check "check_swap plugin exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/lib64/nagios/plugins/check_swap"

check "check_procs plugin exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/lib64/nagios/plugins/check_procs"

check "check_mem script exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/local/nagios/libexec/check_mem.sh"

check "check_systemd_units script exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/local/nagios/libexec/check_systemd_units.sh"

check "check_tcp plugin exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/lib64/nagios/plugins/check_tcp"

check "check_tcp_local script exists" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -x /usr/local/nagios/libexec/check_tcp_local.sh"

check "git available" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "command -v git"

check "podmansock group exists at gid 1500" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "getent group podmansock | grep -q :1500:"

# Guards the mechanism, not just the config. NRPE calls initgroups() when it
# drops privileges, rebuilding the group set from this image -- so membership
# has to be visible in `id nrpe` or socket access silently breaks at runtime.
check "nrpe is in podmansock" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "id -nG nrpe | grep -qw podmansock"

echo ""
echo "=== Runtime tests ==="

container=$($RUNTIME run -d --name nrpe-test --rm "$IMAGE")

sleep 2

check "nrpe process running" \
    $RUNTIME exec nrpe-test pgrep -x nrpe

check "port 5666 listening" \
    $RUNTIME exec nrpe-test sh -c "ss -tlnp | grep 5666"

$RUNTIME stop nrpe-test >/dev/null 2>&1 || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
