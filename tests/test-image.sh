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

# Nothing parsed these before. A plugin with a syntax error still ships, still
# gets chmod +x, and only announces itself as a UNKNOWN on a live host.
check "all libexec scripts parse" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    'for f in /usr/local/nagios/libexec/*.sh; do bash -n "$f" || exit 1; done'

# The coverage check is useless if it cannot reach the podman socket, so it must
# say UNKNOWN rather than inventing a clean fleet. Exercising the guard also
# proves the script runs end to end, which is the part CI can verify without a
# socket to talk to.
check "check_syslog_coverage reports UNKNOWN with no podman socket" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    '/usr/local/nagios/libexec/check_syslog_coverage.sh /tmp/nonexistent-log-root; [ $? -eq 3 ]'

# RT #1498. The cross-repo drift check is useless without its source map, and
# the map is the only part of it that lives in the image rather than in /srv.
check "config-sources.conf ships in the image" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "test -s /etc/nagios/config-sources.conf"

# Every service directory must get an answer -- a repo name or an explicit
# "none". A line with one field is a half-finished edit, and the check would
# silently treat that service as unmapped rather than unowned.
check "every config-sources.conf entry names a repo or none" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    'grep -vE "^[[:space:]]*(#|$)" /etc/nagios/config-sources.conf | awk "NF != 2 { bad = 1 } END { exit bad }"'

# Honesty rule: no source map means no comparison happened, which is UNKNOWN,
# never OK. Exercising the guard also proves the plugin parses and runs end to
# end without a podman socket to talk to.
check "check_config_drift reports UNKNOWN with no source map" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    'CONFIG_DRIFT_CONF=/tmp/nonexistent.conf /usr/local/nagios/libexec/check_config_drift.sh; [ $? -eq 3 ]'

# The collector must answer with a parseable error sentinel rather than dying,
# or the plugin reports "output truncated" and hides the real cause.
check "config-drift-collect reports repo_not_mounted without /var/srv" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    'CONFIG_DRIFT_REPO=/tmp/nonexistent /usr/local/nagios/libexec/config-drift-collect.sh | grep -q "CFGDRIFT error=repo_not_mounted"'

# RT #1497. Same honesty rule as the drift collector: no /var/srv means no
# measurement happened, which must surface as a parseable error sentinel rather
# than a crash the plugin would report as "output truncated".
check "srv-nightly-dump-collect reports base_not_mounted without /var/srv" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    'BASE=/tmp/nonexistent /usr/local/nagios/libexec/srv-nightly-dump-collect.sh | grep -q "NDUMP error=base_not_mounted"'

# No podman socket in CI, so the collector exec fails -- which must be UNKNOWN,
# never a false OK. Also proves the plugin parses and runs end to end.
check "check_nightly_dump reports UNKNOWN with no podman socket" \
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c \
    '/usr/local/nagios/libexec/check_nightly_dump.sh; [ $? -eq 3 ]'

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
