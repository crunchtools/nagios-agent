#!/bin/bash
# Boot gate, run INSIDE the built image (the `image-gate` check in
# pyproject.toml's [tool.sdlc.ci]). It is tests/test-image.sh with `podman run`
# taken out: the same assertions, asked of the image they describe rather than
# of a runtime outside it. The gate runs with no capabilities, no network and a
# read-only /repo, and argv[0] replaces the NRPE entrypoint. The offline plugin
# suite (tests/test-plugins.sh) needs no image, so it is the `plugin-tests`
# check instead, in its own harness (tests/Containerfile.plugins).
set -euo pipefail

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
    test -x /usr/sbin/nrpe

check "nrpe config exists" \
    test -f /etc/nagios/nrpe.cfg

check "check_load plugin exists" \
    test -x /usr/lib64/nagios/plugins/check_load

check "check_disk plugin exists" \
    test -x /usr/lib64/nagios/plugins/check_disk

check "check_swap plugin exists" \
    test -x /usr/lib64/nagios/plugins/check_swap

check "check_procs plugin exists" \
    test -x /usr/lib64/nagios/plugins/check_procs

check "check_mem script exists" \
    test -x /usr/local/nagios/libexec/check_mem.sh

check "check_systemd_units script exists" \
    test -x /usr/local/nagios/libexec/check_systemd_units.sh

check "check_tcp plugin exists" \
    test -x /usr/lib64/nagios/plugins/check_tcp

check "check_tcp_local script exists" \
    test -x /usr/local/nagios/libexec/check_tcp_local.sh

check "git available" \
    command -v git

check "podmansock group exists at gid 1500" \
    bash -c "getent group podmansock | grep -q :1500:"

# Guards the mechanism, not just the config. NRPE calls initgroups() when it
# drops privileges, rebuilding the group set from this image -- so membership
# has to be visible in `id nrpe` or socket access silently breaks at runtime.
check "nrpe is in podmansock" \
    bash -c "id -nG nrpe | grep -qw podmansock"

# Nothing parsed these before. A plugin with a syntax error still ships, still
# gets chmod +x, and only announces itself as a UNKNOWN on a live host.
check "all libexec scripts parse" \
    bash -c 'for f in /usr/local/nagios/libexec/*.sh; do bash -n "$f" || exit 1; done'

# The coverage check is useless if it cannot reach the podman socket, so it must
# say UNKNOWN rather than inventing a clean fleet. Exercising the guard also
# proves the script runs end to end, which is the part CI can verify without a
# socket to talk to.
check "check_syslog_coverage reports UNKNOWN with no podman socket" \
    bash -c '/usr/local/nagios/libexec/check_syslog_coverage.sh /tmp/nonexistent-log-root; [ $? -eq 3 ]'

# RT #1498. The cross-repo drift check is useless without its source map, and
# the map is the only part of it that lives in the image rather than in /srv.
check "config-sources.conf ships in the image" \
    test -s /etc/nagios/config-sources.conf

# Every service directory must get an answer -- a repo name or an explicit
# "none". A line with one field is a half-finished edit, and the check would
# silently treat that service as unmapped rather than unowned.
check "every config-sources.conf entry names a repo or none" \
    bash -c 'grep -vE "^[[:space:]]*(#|$)" /etc/nagios/config-sources.conf | awk "NF != 2 { bad = 1 } END { exit bad }"'

# Honesty rule: no source map means no comparison happened, which is UNKNOWN,
# never OK. Exercising the guard also proves the plugin parses and runs end to
# end without a podman socket to talk to.
check "check_config_drift reports UNKNOWN with no source map" \
    bash -c 'CONFIG_DRIFT_CONF=/tmp/nonexistent.conf /usr/local/nagios/libexec/check_config_drift.sh; [ $? -eq 3 ]'

# The collector must answer with a parseable error sentinel rather than dying,
# or the plugin reports "output truncated" and hides the real cause.
check "config-drift-collect reports repo_not_mounted without /var/srv" \
    bash -c 'CONFIG_DRIFT_REPO=/tmp/nonexistent /usr/local/nagios/libexec/config-drift-collect.sh | grep -q "CFGDRIFT error=repo_not_mounted"'

# RT #1497. Same honesty rule as the drift collector: no /var/srv means no
# measurement happened, which must surface as a parseable error sentinel rather
# than a crash the plugin would report as "output truncated".
check "srv-nightly-dump-collect reports base_not_mounted without /var/srv" \
    bash -c 'BASE=/tmp/nonexistent /usr/local/nagios/libexec/srv-nightly-dump-collect.sh | grep -q "NDUMP error=base_not_mounted"'

# No podman socket in CI, so the collector exec fails -- which must be UNKNOWN,
# never a false OK. Also proves the plugin parses and runs end to end.
check "check_nightly_dump reports UNKNOWN with no podman socket" \
    bash -c '/usr/local/nagios/libexec/check_nightly_dump.sh; [ $? -eq 3 ]'

# 7.0.0. The image carries the state dir and flock, and with no status file and
# no socket the backup check must be UNKNOWN "collector stale", never a verdict.
check "backup state dir exists and flock is installed" \
    bash -c 'test -d /var/lib/nagios-agent && command -v flock'
check "check_backup_freshness is UNKNOWN collector stale with no status file" \
    bash -c '/usr/local/nagios/libexec/check_backup_freshness.sh | grep -q "collector stale"'
# 7.1.0. The outside-API checks load collector-lib.sh from beside them and,
# with no status file and no socket, are UNKNOWN "collector stale" too.
check "outside-API checks are UNKNOWN collector stale with no status file" \
    bash -c 'cd /usr/local/nagios/libexec && printf "%s\n" "check_cloudflare_status.sh example.com" check_cloudflare_global.sh "check_quay_staleness.sh example/x 8 latest" check_registry_drift.sh | while read -r c; do ./$c | grep -q "UNKNOWN - collector stale" || { echo "not stale: $c"; exit 1; }; done'

echo ""
echo "=== Runtime tests ==="

# NOT the old nrpe-process and port-5666 assertions. The gate runs with every
# capability dropped, and nrpe exits 2 at startup without DAC_OVERRIDE, which
# `command` cannot grant a non-systemd image (this image boots no systemd).
# What a no-capability run can still prove is that the binary loads: a missing
# shared library fails here, where it would have failed nrpe's startup.
check "nrpe binary has every shared library" \
    bash -c '! ldd /usr/sbin/nrpe | grep "not found"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
