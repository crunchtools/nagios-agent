# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `check_container_restart.sh` — alerts on a container that restarted inside a
  configurable window. Detects the failure mode behind RT #1459: a container is
  OOM-killed, `Restart=always` brings it back in ~2s, and every "is it running"
  check reports OK again before the next poll, so a real outage leaves no state
  to alert on. These units run with `--rm`, so `State.StartedAt` is the only
  field that moves; the check reads it from the podman socket, no token needed.
- `deploy/nagios/nrpe-agent-restart.cfg` — Nagios service definitions putting
  the two NRPE pools under mutual watch, so neither daemon is the sole witness
  to its own death.
- `.github/workflows/gatehouse.yml` and a `Code Quality (Gourmand)` job in
  `build.yml` — the CI gates required by constitution XII, previously absent.
- `.specify/memory/constitution.md` — profile declaration required by
  constitution VII, previously absent.
- `CHANGELOG.md` — this file, required by constitution II.

### Fixed

- Raised the `nagios-agent` container memory cap from 512m to 1g in the deployed
  unit. `check_backup_freshness` runs 19 pCloud sentinels in waves of 7 at
  ~70MB per rclone process, measured peak 490MB — 96% of the old cap. Any
  concurrent check tipped the cgroup over and the kernel OOM-killed the NRPE
  daemon: seven kills on 2026-09-19, each one a gap in the fast pool that
  surfaced only as `connect to address 10.88.0.1 port 5666: Connection refused`
  in the Nagios log. (Deployed-unit change; recorded here because the cap is
  part of this agent's contract.)

### Changed

- `Backup Freshness` check interval moved from the inherited 1 minute to 30
  minutes. Its thresholds are measured in days (WARN 9d), so a minute-resolution
  poll bought nothing and cost a 490MB spike inside the agent every 60s plus
  ~27,360 pCloud listings a day. 30 minutes still detects a missed weekly dump
  hundreds of checks before it goes warning.
