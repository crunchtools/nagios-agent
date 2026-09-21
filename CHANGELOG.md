# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.0] - 2026-09-20

### Added

- `check_nightly_dump.sh` and `srv-nightly-dump-collect.sh` — freshness of the
  nightly in-container database dumps, read on disk before they reach pCloud
  (RT #1497).

  Three services dump their own database nightly from a cron or timer inside
  their own container — learn (`my_wiki.sql`, `export.xml`), rt (`rt4.sql`),
  postiz (`postiz-*.sql.gz`) — on top of the weekly pbs dump.
  `check_backup_freshness.sh` already watches these, but only the pCloud copies,
  and pCloud only refreshes on the Saturday sync. So a nightly job that dies
  mid-week is invisible for up to seven days: the dump on disk goes stale while
  its pCloud sentinel stays green, because the weekly artifact it reads is still
  fine. The exposure degrades to the weekly baseline, which is monitored — but
  not to zero, and it is exactly the kind of thing that stays broken for months
  because nothing says so.

  The new check reads the dumps where they land first, under `/var/srv`, and goes
  WARNING at 36h / CRITICAL at 50h (a missed night plus margin / two missed
  nights), with a per-service size floor so a dump that exits 0 but writes
  near-empty is caught too. It escalates to root via `podman_exec.sh` — the same
  privilege split as the drift checks, and for the same reason: postiz writes its
  dump `0600` in a `0700` dir (it plausibly holds social OAuth tokens), so nrpe
  cannot stat it and loosening the mode is the wrong fix. The collector reports
  only a label, mtime, size and floor per service; all policy lives in the
  plugin. No new mount — `/var/srv` is already ro-mounted for the drift checks,
  which retires the mount concern the ticket had flagged as the cost of this fix.

## [1.1.0] - 2026-09-20

### Added

- `check_config_drift.sh` and `config-drift-collect.sh` — the third drift door:
  a deployed config file that TWO git repos both claim (RT #1498).

  On 2026-09-20 `proxy.crunchtools.com.conf` was tracked by
  `fatherlinux/lotor.dc3.crunchtools.com-srv` (deployed, bind-mounted, watched)
  and by `crunchtools/proxy` (a reference copy four vhosts behind). Syncing the
  host file from the second one deleted the trentina, mcp-gw-personal,
  mcp-gw-work and mcp-pcloud vhosts and left josui's gateway answering 403
  until the backup was restored. `check_git_drift` and `check_unit_drift` both
  read green throughout, correctly: neither can see a second repo, so from
  inside either one nothing had drifted. The comparison nobody was making was
  between them.

  The new check makes it. `config-drift-collect.sh` runs as root in the agent
  container — same privilege split as `srv-drift-collect.sh`, for the same
  reason — and publishes a path-and-blob-SHA fingerprint of every tracked file
  under `/srv/<service>/config/`. Paths and hashes cross the boundary, never
  contents, and files that carry secrets (`.env`, keys, certs, `wp-config.php`)
  are published with no hash at all. `check_config_drift.sh` runs unprivileged,
  shallow-blobless-clones each project repo named in `config-sources.conf`, and
  compares blob SHAs straight out of `git ls-tree` — so no repository content is
  downloaded and the GitHub REST API, whose unauthenticated budget of 60 calls
  an hour would not survive ~30 repos plus a retry, is never touched.

  Four counters, four different fixes: `divergent` (a rival copy that disagrees
  — the loaded gun), `duplicate` (a rival copy that currently matches — perfdata
  only, an amber tile for this would become furniture), `unpublished` (deployed
  content that `origin/master` does not hold, measured per file as a hash rather
  than as repo state), and `secret_exposed` (Constitution XVII — a deployed
  secret file that also lives in a project repo, where presence is the finding
  and content is irrelevant). CRITICAL is deliberately narrow, because hermes
  notifies on CRITICAL only: a secret in a project repo, or a file that is
  simultaneously unpublished and contradicted by a rival, which is the
  2026-09-20 state exactly. Everything else is WARNING.

  Files under `rootfs/` in a project repo are image content, not a second home —
  `/srv` is *supposed* to override them per Constitution XIV — and are skipped,
  as are Containerfiles. Candidates are scored by longest common trailing path
  suffix with a unique winner, because matching on basename alone pairs the
  deployed `config/temporal/config.yaml` with postiz's `.gemini/config.yaml` and
  invents drift that does not exist; a tie is reported as `ambiguous` rather
  than guessed at.

  First run on lotor: 265 deployed config files, 9 divergent across acquacotta,
  factory, mcp-syslog, openclaw, postiz, spanish and syslog, 6 duplicates, 0
  exposed secrets. The check ships visibly amber and the list is the work.
  `CONFIG_DRIFT_MAX_DIVERGENT` is a ratchet for walking it down.

- `rootfs/etc/nagios/config-sources.conf` — every service directory under
  `/srv` and the project repo that could plausibly claim to own its config.

  Cannot be inferred: the directory is the vhost and the repo is the project,
  and they disagree often enough that guessing would be wrong rather than
  merely incomplete (`mcp-feeds` → `mcp-feed-reader`, `mcp-jira` →
  `mcp-atlassian`, `mail` → `postfix`, both gateways → one
  `google-workspace-mcp`). `none` is an explicit answer for a service with no
  project repo; an unlisted directory is counted as unmapped and named in the
  headline, because silently not looking is how the outage stayed invisible.

- `check_syslog_coverage.sh` now reports MISFILED containers, and warns on them.

  The check asked one question: does `<log_root>/<container_name>` exist? A
  systemd container whose unit omits `--hostname` forwards under its podman ID,
  so its logs land in a directory named `31094d135f31` — collected and retained,
  findable by nobody. That looked identical to a container that is simply quiet,
  which the check deliberately never alerts on. Two production services sat
  misfiled for three weeks behind an `OK` (RT #1460).

  It now also asks whether the container is writing under its own 12-character
  ID, which is unambiguous, and exits WARNING with the names when it is. The
  healthy value is always zero and the fix is a known one-line unit change, so
  unlike `no_logs` this one is safe to page on. New perfdata: `misfiled=`.
  Costs no extra podman call — the ID comes from the inspect the check already
  made for the log driver.

- Two CI tests for the plugins, which had none.

  `all libexec scripts parse` runs `bash -n` over every plugin; a syntax error
  previously shipped, got `chmod +x`, and announced itself as a UNKNOWN on a
  live host. `check_syslog_coverage reports UNKNOWN with no podman socket`
  exercises the guard path — a coverage check that cannot reach the socket must
  say so rather than invent a clean fleet — and proves the script runs end to
  end, which is the part CI can verify without a socket to talk to.

### Changed

- Both agent units bind-mount the host journal socket at `/dev/log`, and the
  NRPE configs document why.

  `log_facility=daemon` writes via `syslog(3)` to `/dev/log`. These containers
  had no such socket, so every NRPE message — startup, listener binding, host
  rejections — was discarded at the libc call, silently. Both agents were
  invisible to the central collector for that reason, not because they were
  quiet (RT #1460).

  `log_file=/dev/stdout` is NOT the fix and the configs now say so: NRPE points
  its own fd 1 and 2 at `/dev/null` before it opens the log file, so the
  messages go to `/dev/null` and nothing reports an error. Verified on
  nrpe-4.1.3. Entries land in the host journal under `SYSLOG_IDENTIFIER=nrpe`;
  they carry no `CONTAINER_NAME`, so the collector files both pools together
  under `nrpe` rather than per-container. The port in each message
  ("Server listening on 0.0.0.0 port 5666") distinguishes them.

### Changed

- `deploy/nagios-agent/nrpe-ctr.cfg` and `nrpe-host.cfg` had fallen behind the
  configs actually running on lotor. The repo documents these as "the agent units
  and NRPE configs as deployed" and they were not: production carried five command
  definitions this repo had never seen —

  | file | missing command |
  |------|-----------------|
  | nrpe-ctr.cfg | `check_ctr_run_mcp_systemd` |
  | nrpe-ctr.cfg | `check_ctr_mem_mcp_systemd` |
  | nrpe-ctr.cfg | `check_factory_status` (RT #1478) |
  | nrpe-host.cfg | `check_tcp_8022` |
  | nrpe-host.cfg | `check_plugin_drift` (RT #1490) |

  `check_plugin_drift` is the pointed one: the check built to catch exactly this
  class of drift was itself untracked.

  Drift was one-directional — nothing in the repo was absent from production — so
  this is a pure catch-up. Both files now match production command-for-command
  including arguments. The systemd units and four of the five
  `deploy/nagios/*.cfg` service definitions were already identical.

  **Not resolved here:** `deploy/nagios/registry-drift.cfg` exists in this repo as
  a standalone file, but the running service is defined inline in the Nagios
  server's `services/host-checks.cfg` with different `notes` text and without this
  file's `check_interval`/`retry_interval`. Deploying the repo copy as-is would
  define the service twice. Which representation is canonical is a decision, not a
  sync, so it is left alone and called out rather than papered over.

### Fixed

- `check_registry_drift.sh` went CRITICAL during deploys. It made ~170 network
  calls serially and took **38.6s** against check_nrpe's 45s ceiling — 86% of the
  budget — so any registry latency tipped it into
  `CHECK_NRPE STATE CRITICAL: Socket timeout after 45 seconds`. It did exactly
  that three times during one deploy on 2026-09-20 while the real answer was a
  clean 56/56. That is the worst failure mode a check can have: it cries wolf
  precisely when someone is watching, which trains everyone to ignore it.

  The per-image work is now a `check_one` function that prints a single verdict
  line, run concurrently via `xargs -P` (8 by default, `REGISTRY_DRIFT_JOBS`).
  Tallying stays sequential in one reader, so the counting logic is unchanged.
  Runtime **38.6s → 5.0s**, output byte-identical. Verdicts are sorted before
  tallying, because workers finish in network order and the detail list would
  otherwise shuffle between runs of an unchanged check.

  The honesty rule is intact: unreachable git, Quay and GHCR were each exercised
  and still produce `unknown` and the UNKNOWN exit, not a false OK.

- `check_postiz_tokens.sh` sent the operator to do work Postiz does on its own,
  and did not say what that work was. It warned `threads(21d) (reconnect in the
  Postiz UI)` — naming no account, no UI path, and no reason. Threads was never
  the problem: it stores a refresh token and Postiz renews it through a Temporal
  `refreshTokenWorkflow` that sleeps until expiry and then extends it ~58 days.
  The check had no way to tell that apart from LinkedIn, which stores no refresh
  token at all and genuinely does need a human every ~60 days.

  The check now reads the refresh token's presence alongside `refreshNeeded` and
  splits channels into self-renewing and manual. Day thresholds apply only to
  manual channels. Self-renewing ones are exempt from them but keep both hard
  backstops: `refreshNeeded` flipping, or the token running past expiry, is still
  CRITICAL — so a dead renewal workflow cannot hide. Alerts now name the account
  and the exact remedy, and the OK line reports each class separately, bounded to
  the next year so channels expiring in 2058 stay out of it.

  ```
  WARNING - Postiz: linkedin (Scott McCarty) expires in 19d and cannot auto-renew
    -- reconnect at https://postiz.crunchtools.com via Add Channel, signing in as the same account

  OK - 6 Postiz integrations valid, none expiring within 21d
    -- manual: linkedin 52d -- auto-renewing: threads 57d
  ```

  Sections are joined with ` -- `, never `|`. Nagios splits plugin output on the
  first pipe and files the remainder as performance data: an earlier cut of this
  check used `|` as a visual separator and Nagios duly parsed
  `manual: linkedin 52d | auto-renewing: threads 57d` into `performance_data`,
  which would have stripped the remedy text out of the alert and the notification
  mail — removing the one thing this change exists to add.

  Reconnecting is "Add Channel", not clicking the channel: the in-place reconnect
  badge only renders once `refreshNeeded` is set, so it is unavailable for a
  planned re-auth. Re-running OAuth upserts on `(organizationId, internalId)`, so
  the existing channel is updated rather than duplicated and queued posts survive.

## [1.0.0] - 2026-09-20

First tagged release. This agent has been running in production since
before it had version control; this release marks the current state as
the baseline going forward.

### Fixed

- `check_container_zombies.sh` reported UNKNOWN on minimal/hardened images
  (RT #1493). It execs `ps aux` inside the target via `podman_exec.sh`;
  images with no procps (mcp-ashigaru and the rest of the Hummingbird-based
  fleet) exit 127. Switched to the podman Engine API's
  `/containers/{id}/top` endpoint, which runs `ps` on the host against the
  container's PIDs via the kernel PID namespace — no binary needs to exist
  inside the target. Verified against mcp-ashigaru (UNKNOWN → OK), a
  nonexistent container (still UNKNOWN, with the real error), and a normal
  container.
- `check_quay_pull_source.sh` reported OK when it could not run (RT #1481). It
  read host units via `nsenter -t 1 -m`, which needs CAP_SYS_ADMIN and root;
  NRPE runs plugins as `nrpe`, so the nsenter always failed, and every failure
  mode collapsed into the same empty-string branch with stderr discarded. It
  now reads the read-only `/etc/systemd/system` bind mount that RT #1477 added,
  and exits UNKNOWN when the mount is missing, unreadable or empty. Unreadable
  entries — mostly enablement symlinks into the unmounted `/usr/lib/systemd/system`
  — are skipped and counted rather than aborting the scan. Verified in the agent
  container as `nrpe`: 55 units scanned, 3 skipped, 0 violations.
- `check_systemd_units.sh` had never once looked at the host (found during the
  RT #1481 sweep). The container has no `/run/systemd` and no system bus, so
  `systemctl` answers "Running in chroot, ignoring command" as root and "System
  has not been booted with systemd as init system" as `nrpe`. The old code piped
  that into `grep -c`, got 0, and printed "OK - No failed systemd units"
  unconditionally — the host had 529 units and the container saw none. It now
  checks systemctl's exit status, treats any stderr as proof it did not query,
  and confirms a live manager via `systemctl is-system-running` before trusting
  a zero count. This does not restore host visibility, which needs a bus socket
  or a privilege split and is tracked separately; it stops the check lying.

- Removed identifiable data from config destined for this public repo, per
  universal constitution XVII. `nrpe-ctr.cfg` carried four Cloudflare zone IDs
  and two mail addresses inline as check arguments. Neither is a credential —
  the Cloudflare API token was already a separate host-side file — but zone IDs
  map infrastructure to an owner and there is no reason to publish either.
  `check_cloudflare_status.sh` now takes `<domain>` and `check_google_oauth.sh`
  takes `<account-key>`, both resolving the real value host-side from
  `cloudflare-zones.conf` / `google-accounts.conf`. The repo carries only
  `.conf.example` files showing the shape.
- Raised the `nagios-agent` container memory cap from 512m to 1g in the deployed
  unit. `check_backup_freshness` runs 19 pCloud sentinels in waves of 7 at
  ~70MB per rclone process, measured peak 490MB — 96% of the old cap. Any
  concurrent check tipped the cgroup over and the kernel OOM-killed the NRPE
  daemon: seven kills on 2026-09-19, each one a gap in the fast pool that
  surfaced only as `connect to address 10.88.0.1 port 5666: Connection refused`
  in the Nagios log. (Deployed-unit change; recorded here because the cap is
  part of this agent's contract.)

### Added

- `check_factory_status.sh` + `deploy/nagios/factory-status.cfg` — surfaces the
  factory watchdog's verdict to Nagios (RT #1478). The watchdog evaluates every
  repo in the org hourly and its only alerting path was a Zabbix trapper that
  died with RT #1459, so ~47 repos' health went to a closed socket. Reads the
  status file straight off the host bind mount — no credential, no podman exec,
  no dependency on the dashboard process. Staleness is the CRITICAL case.
- `deploy/nagios-agent/` and `deploy/systemd/` — the deployed NRPE configs and
  both agent unit files, captured into git for the first time. These decide
  whether anyone gets paged and previously existed only on the host's filesystem.
- `deploy/nagios/backup-freshness.cfg` — likewise.
- `check_google_oauth.sh` — brought into the repo (sanitized); it is named as a
  reference implementation by universal constitution XVI but was in no repo.

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

### Changed

- `Backup Freshness` check interval moved from the inherited 1 minute to 30
  minutes. Its thresholds are measured in days (WARN 9d), so a minute-resolution
  poll bought nothing and cost a 490MB spike inside the agent every 60s plus
  ~27,360 pCloud listings a day. 30 minutes still detects a missed weekly dump
  hundreds of checks before it goes warning.
