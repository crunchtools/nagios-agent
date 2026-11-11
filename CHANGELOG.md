# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [9.12.0] - 2026-11-11

### Changed

- `check_image_cve.sh` now pages on CHANGE, not on the standing backlog
  (RT #1551). A fixable Critical pages (CRITICAL) only when its `(image, CVE)`
  is NOT in the accepted baseline (`cve-baseline.conf`); a Critical already in
  the baseline is known, counted as `baselined_crit`, and does not page. A
  regression — a new CVE, a known CVE surfacing in a new image, or (fail-safe) a
  counted Critical with no finding line to attribute to a baseline entry —
  still pages. This replaces the previous count-only routing, which would have
  paged on the whole known backlog and trained the fleet to ignore the page.
  The fix for a CRITICAL is a version BUMP (base/dependency), not a same-commit
  rebuild — stated in the check and the service notes.

### Added

- `cve-baseline.conf` — the accepted `(image, CVE)` baseline, mounted into the
  nagios-agent container at `/etc/nagios/cve-baseline.conf` and seeded from the
  live findings at go-live. New `CVE_BASELINE` env on the `check_image_cve`
  nrpe-ctr command; a new perfdata set (`new_crit`, `baselined_crit`,
  `baseline`, `stale_baseline`). An empty or missing baseline accepts nothing
  (every fixable Critical pages) — the fail-safe before seeding.

## [9.11.0] - 2026-11-11

### Added

- `check_image_cve.sh` — fleet image CVE check (RT #1551). Reads `cve.status`
  written by the `quay.io/crunchtools/grype` oneshot and routes: CRITICAL on a
  fixable Critical CVE, WARNING on a fixable High, UNKNOWN (notifying) when the
  scan is stale, the scanner's vulnerability DB is older than 48h, or a listed
  image is absent from the scan; OK when only unfixable findings remain. One
  service (`Fleet image CVEs`) that names the offending images; a coverage gap
  never masks a real CRITICAL. Image age staleness stays with
  `check_quay_staleness.sh`. Adds the `check_image_cve` nrpe-ctr command and the
  `image-cve.cfg` service definition.

## [9.10.0] - 2026-11-11

### Changed

- Registry drift reads Quay only. GHCR is dropped fleet-wide (RT#1550), so
  the GHCR tag listing and the Quay-vs-GHCR comparison are gone.
- The image is built once per change and promoted by digest through
  constitution's container-release workflow (RT#1550): the merge copies the
  pull request's gated digest to `:main` and a `v*` tag copies it to
  `:latest`. Nagios no longer rebuilds on merge.

### Removed

- `check_agent_gateway_stale.sh` and the four `Agent gateway <seat>` checks
  (josui, developer1-3). The check paged when the Trentina gateway's container
  started *after* an agent's, on the premise that a gateway restart silently
  kills the agent's MCP session and only an agent restart brings it back
  (RT#1556). Trentina #775 (session adoption) ends that failure mode: on
  restart the gateway now adopts the session ids its clients are still holding
  and they carry on working, so "gateway newer than the agent" no longer means
  a dead client — it only false-positives. All four seats paged after the #775
  deploy while fully healthy (Josui confirmed its own flagged seat was calling
  tools normally). The server-side service definitions (`agent-gateway.cfg`)
  were removed from gloval `/srv` and nagios reloaded separately; this change
  drops the NRPE command, the plugin, its test block, and its gourmand
  exception.

## [9.9.2] - 2026-11-09

### Fixed

- Deploy drift no longer reports a container as `stale` when only the image
  index moved. The collector compared the container's `ImageDigest` with the
  `manifest_digest` Quay holds for the tag, and both are OCI **index**
  digests. A rebuild at the same commit re-generates the provenance
  **attestation** manifest, which is a child of the index, so the index digest
  changes while the runnable per-architecture manifest -- and therefore the
  image -- is byte for byte what it was. `openclaw:latest` was rebuilt that
  way on 2026-11-07 and takeda read as stale from then on: it was running the
  right image, `podman auto-update --dry-run` said there was nothing to apply,
  and nothing could ever clear the WARNING. Before reporting drift the
  collector now asks podman whether the tag's current digest is among the
  RepoDigests of the image the container is actually running, which is podman's
  own record that the manifest resolved to those bits. One local socket call,
  taken only on the path that would otherwise report drift; a miss or a failed
  read still reports `stale`, so it can only clear drift it can prove is not
  drift.

- Config drift no longer reports `unpublished` for files the mapped repo holds
  byte for byte under another path (e.g. `rootfs/`). The repos collector
  re-tests each unpublished path by content hash against the repo's whole tree.

## [9.9.1] - 2026-11-09

### Fixed

- `check_openbao.sh` would have run `rm -f /dev/null` as root. Keeping curl's
  diagnostic meant a temporary file, and the fallback when `mktemp` fails was
  `err=/dev/null` — which the EXIT trap then removed. This check runs as root
  under NRPE, so that unlinks the system's null device and breaks every process
  that opens it. The fallback is an empty `err` now and the trap is guarded.
  Caught by Gatehouse at HIGH on #158 before it ever ran as root — introduced
  and fixed within the same PR.

- `check_openbao.sh` emitted `sealed=true` / `sealed=false` as perfdata. Nagios
  perfdata values are numbers or `U`, so the one metric this check advertised as
  graphable was never graphable — it has been like that since 9.9.0 shipped this
  morning. Now 1 for sealed, 0 for unsealed, `U` when it cannot tell; the
  human-readable half keeps the words, because that is what gets read in an
  alert. Found by Gatehouse on #158.
- `check_openbao.sh` discarded curl's stderr, so a timeout, a TLS verification
  failure and a refused connection all arrived as the same "no answer" — three
  different jobs, one message. The diagnostic is now included, and deliberately
  **before** the pipe: everything after it is perfdata, so prose appended there
  is parsed as a metric and the whole perfdata string is discarded. Adding a
  diagnostic the naive way would have cost the graph. Both arms are tested and
  mutation-tested.

### Changed

- `openbao.crunchtools.com` keeps its `none` mapping, but for a different
  reason, and the comment now says which. When 9.9.0 shipped that morning the
  answer came straight from the rule: the unit pulled the upstream image and
  nothing outside `/srv` carried a copy of its config. That was also the
  finding, and by the afternoon the image was `quay.io/crunchtools/openbao`,
  built from `crunchtools/openbao` with the operator tools in it and under
  test. The mapping still does not move, because that repo is private and a
  listed repo is read with one anonymous clone and no token -- pointing at it
  would report `openbao` as "unchecked" every run, which looks like a transient
  failure rather than a decision. Stated with the cost it accepts: nothing
  compares openbao's deployed units against the repo copies.

## [9.9.0] - 2026-11-09

### Added

- `check_openbao.sh`: is gloval's OpenBao up and unsealed? It has been running
  on gloval since the RT#1604 cutover, wired by host-side overrides only, so
  the image never carried it and a rebuild would have dropped it. Released now
  with its `command[check_openbao]` NRPE definition. The check uses the
  UNAUTHENTICATED `/v1/sys/health`, so no token, role_id or secret_id enters
  the monitoring path, and it parses with sed rather than jq because the agent
  image has neither jq nor python3. Treat CRITICAL as "the host cannot boot
  cleanly": every `srv-secrets@` oneshot fetches from this server and every
  service unit `Requires=` its oneshot, so a sealed store stops the whole host
  rather than degrading one service.

### Changed

- `config-sources.conf`: map `openbao.crunchtools.com` to `none`. It was the
  one UNMAPPED service in the config-drift check on gloval. Applying the file's
  own rule -- read the unit, see what image it pulls -- the answer is the
  upstream image pinned by digest, so no crunchtools repo builds it and nothing
  outside /srv holds a copy of its config. "none" is the answer, not a shrug,
  and saying so is what distinguishes "we looked and found nothing" from
  "nobody ever looked".

## [9.8.0] - 2026-11-09

### Added

- `check_mcp_tool.sh` and `mcp-probes.conf.example`: one real tool call per MCP
  service, because liveness was never what broke (RT #1565). Every
  `ctr-mcp-*` host had exactly three checks — container running, container
  memory, MCP port — and all three passed for the entire 2026-11-07 mcp-gemini
  outage, during which every tool returned `Gemini API error: Attempted to call
  a sync close on an async stream`. The process was up and the socket accepted
  connections. The outage was found by needing the tool.

  The plugin opens a streamable-http session, calls ONE free read-only tool,
  and asserts a regex against the result. The assertion is the load-bearing
  part: that outage answered HTTP 200 with `isError` false and an error string
  as its content, so a check confirming only that the server replied would have
  stayed green throughout. `tests/test-plugins.sh` encodes that exact shape as a
  regression test.

  bash and curl only — the image has no python and no jq. Handles stateful
  servers (session id, `notifications/initialized`) and the two stateless ones
  that return neither, and deletes its session rather than leaking one into
  every server on every interval.

  The per-service tool, arguments, assertion and `local`/`upstream:<who>` scope
  live in `mcp-probes.conf`, resolved from an opaque key — the
  `check_google_oauth.sh` pattern, for the same two reasons: `nrpe-ctr.cfg` is
  published and one probe carries a mail address, and NRPE command definitions
  are a poor home for JSON and regex. The two servers needing a bearer token
  get it from the target container's own environment through the podman socket,
  so no credential is copied into `/srv`.

  The scope tag is printed in the alert. The probe cannot distinguish our bug
  from a third party's outage — an expired credential, a server bug and GitHub
  being down are identical from here — so the tag is a declared fact that lets
  the triaging agent route without reading the table.

- `deploy/nagios/mcp-tool-calls.cfg`: the 23 `MCP tool call` service
  definitions, on the `:5667` pool so probes blocking on a third-party API
  cannot queue behind the host diagnostics. `check_interval 15`,
  `retry_interval 3`; with `max_check_attempts 3` a transient blip needs about
  six minutes of consecutive failure to page.

- `nagios-agent-ctr.crunchtools.com.service` mounts `mcp-probes.conf` at
  `/etc/nagios/mcp-probes.conf`.

  Verified end-to-end via `check_nrpe` from the Nagios server, including the
  failure branch: stopping `learn.fatherlinux.com` drove `ctr-mcp-wiki` /
  `MCP tool call` to CRITICAL while container running, container memory and MCP
  port all stayed OK, and restarting it recovered. The first live run also
  found a failure the old checks never saw — mcp-gsc's Search Console OAuth is
  expired, so every one of its tools has been erroring behind three green
  checks.

  Not covered: `ctr-trentina`. The gateway answers 410 Gone on `/mcp` without a
  per-profile JWT, and every one of its backends is now probed individually.

## [9.7.1] - 2026-11-09

### Fixed

- Config drift no longer reports a file ambiguous when two candidates in the
  same repo tie on path suffix and only one of them names the service. A tie
  now goes to the candidate whose path contains the service's /srv directory
  name, so tig's `deploy/telegraf-host/telegraf.conf` and
  `deploy/telegraf-receiver/telegraf.conf` each match their own service. A
  longer suffix still wins outright.
- The source map lists `srv-secrets` (host-local, `none`) and
  `container-storage-prune` (`pbs`), which were reported unmapped.
- The reference units in `deploy/systemd/` match what runs on gloval: both
  require `srv-secrets@nagios-agent.crunchtools.com` and read their env file
  from `/run/srv-secrets` (trentina#768).

## [9.7.0] - 2026-11-09

### Added

- `check_backup_rotation_progress.sh`, `rotation-progress-collect.sh` and the
  **Backup rotation progress** service: **a rotation that never finishes now
  blocks OS updates for ever, and nothing was watching.**

  RT #1594 made every pbs backup rotation hold a systemd block shutdown
  inhibitor for the life of its run, so an OS update cannot reboot the host
  mid-backup — it is refused and retried every 30 minutes until the rotation
  finishes. Verified live: a rotation held an OS update off for over three
  hours. That is the behaviour we wanted, and it introduced a coupling that
  had no watcher: a wedged rotation holds the inhibitor indefinitely, silently.

  Backup Freshness and Personal Backup Freshness cannot see it. They judge the
  markers a rotation writes when it COMPLETES, so a run wedged at hour three is
  byte-identical to a run that never started, and their thresholds are 16 and
  100 days. A wedge surfaced a fortnight late, as staleness, never as
  "something is stuck right now".

  Neither elapsed time nor rclone's byte counter can judge it on its own.
  `ServerBackups-Weekly-1` takes roughly ten hours normally and
  `PersonalBackups-Weekly-1` sixteen minutes, so one clock is either blind or
  pages every Saturday. And on 2026-11-09 a personal rotation whose mirror was
  39 days stale sat at `22.978 GiB / 22.978 GiB, 100%, 0 B/s, ETA -`
  byte-identical for two and a half hours, 4h20m into the run, inside a
  `--delete-during` pass that `--stats-one-line` does not count. That run was
  SLOW, not wedged. What proved it was CPU: about half a CPU-second a minute,
  continuously, with steady memory. Host networking leaves no per-container
  network counters to use instead.

  So the verdict is on both, and a rotation is stuck only when NEITHER its byte
  counter NOR its CPU time has moved — 45m for a personal rotation, 2h for a
  server one. Either one moving is progress, and progress is silent.

  CPU time is cumulative, so proving it stopped needs two samples. That is the
  only reason there is a collector: not a slow read — every call is the local
  podman socket — but a baseline. Sampling twice inside one check run was the
  alternative, and at half a CPU-second a minute a 15-second in-check sample
  can read zero on a bursty process; that check would flap, and a flapping
  detector trains the operator to ignore it. Across a 45-minute window of
  five-minute samples the same rotation accrues ~22 CPU-seconds.

  WARNING on a stall, because a stuck backup blocking OS updates is not an
  emergency. CRITICAL only when it is ALSO past its lifetime ceiling (12h
  personal, 24h server): the run cannot finish and updates have been refused
  for half a day. A run past the ceiling that is still moving warns.

  It never kills or time-bounds a rotation. Bounding a run's lifetime kills a
  backup that might be slow rather than stuck, which is the behaviour RT #1594
  was filed to stop. Visibility is the job.

## [9.6.1] - 2026-11-08

### Changed

- The config-drift source map follows the Telegraf rename (tig#50):
  `telegraf.crunchtools.com` is now `telegraf-host.crunchtools.com`, and
  `telegraf-receiver.crunchtools.com` (the OTLP receiver for Trentina's call
  traces, was `telegraf-otlp`) is mapped to `tig` instead of reported
  unmapped. The reference `nrpe-ctr.cfg` carries the renamed
  `check_ctr_{run,mem}_telegraf_host` and the new `_telegraf_receiver`
  commands, matching what is deployed.

## [9.6.0] - 2026-11-08

### Added

- `check_cold_copy_freshness.sh` and the **Cold Copy Freshness** service:
  **the check the micro-SD never had.**

  Until today the only copy of Scott's personal data outside the pCloud account
  was a 512 GB micro-SD. It had been broken since at least 2026-11-02 — 628 GiB
  of source against a 469 GiB card, full, contents owned by the wrong uid — and
  nobody noticed for months, because nothing watched it. It was retired
  2026-11-07 (RT#1547). Everything else was inside one account: `~/pCloudDrive`
  is the primary store and the "backup" was pCloud to pCloud, with 11 of 15
  server databases single-homed there, `mcp-memory` and `trentina` included.
  pbs 2.6.0's `ColdCopy` module now copies all of it to a 4 TB drive, and this
  service is what keeps that from rotting the same way. It is the point of the
  exercise, not an accessory to it.

  Costs no extra pCloud read: `backup-freshness-collect.sh` already reads that
  whole markers folder with one `rclone cat`, so widening its filter from
  `^Files|` to `^(Files|ColdCopy)\|` picks these up in the same run, and the
  plugin judges the same `personal-backup-freshness.status` file as Personal
  Backup Freshness.

  **No item list in the plugin.** `check_personal_backup_freshness.sh` carries a
  hard-coded `DIRECTORIES` and a warning that it MUST track `pbs.sh`, because a
  name pbs no longer syncs leaves a marker that can never be refreshed and a
  CRITICAL nobody can clear. `ColdCopy` discovers its items from the account at
  runtime, so there is nothing here to drift: this judges whatever the marker
  reports. The failure that replaces "stale name" is "no marker at all", which
  is CRITICAL and is also exactly what a drive nobody plugged in looks like —
  the intended alert, not a false one.

  **It runs on gloval, not on the laptop holding the drive.** The drive is only
  present when Scott docks and unlocks it, so a check beside it could only
  report while it was already running. Reading the marker from pCloud means a
  laptop that is off is the condition that alerts, and nothing here changes when
  the drive moves to a dedicated host — the check follows the marker's hostname.

  WARN 10d / CRIT 24d. The sync is triggered by unlocking the drive rather than
  by a timer (pbs `systemd/breetai/cold-copy.sh` explains why), so the cadence
  is however often Scott docks: three missed weeks is a trip, four is the
  micro-SD happening again.

  **It will not return OK having judged nothing.** A marker line with no item
  name is CRITICAL as a malformed marker rather than skipped, and a marker set
  where nothing parsed at all is CRITICAL too. Skipping those produced
  `OK - 0/0 items fresh`: a monitoring check going green on no evidence, which
  is precisely how the micro-SD stayed unnoticed. Caught by Gatehouse on #149.

## [9.5.0] - 2026-11-08

### Added

- `check_container_storage.sh` and the **Container Storage** service, watching
  the nested podman image stores in `developer1-3` and `gha-runner-cached`.
  Those stores held **1,190,137 files and 49.5 GiB** on 2026-11-08, mostly the
  same image repeatedly — developer1 carried python-sdlc 0.5.3, 0.5.2, 0.5.1,
  0.5.0 *and* 0.2.0 at 988 MB each — and that mass is what stopped the weekly
  pbs `Servers` sync converging: it ran backwards, 93% to 92% over five hours,
  because the CI runner builds while rclone walks it. pbs 2.5.0/2.5.1 took
  those trees out of the backup and `container-storage-prune.service` now keeps
  the newest two tagged images per repository.

  This check is **not** that prune's trigger. The prune runs on its own clock;
  an alert used as a cron only fires when the alert pipeline is healthy, and it
  spends an agent's judgement on deterministic policy. A failed prune run is
  Host Units Watch's business via the unit result. This watches the slower
  truth nothing else notices — the stores climbing again because the prune
  quietly stopped working.

  24 GB warning / 36 GB critical on developer1-3 image bytes, which sat at
  13.3 GB after the first real prune; at ~3 GB/day fleet-wide if the prune
  dies, that is about three days to warning. `gha-runner-cached` is reported as
  context and never counted — its unit calls it a "persistent layer cache" and
  the 17.4 GiB is the point. Volumes are excluded too: developer1's store is
  2.85 GB of images beside a 7.26 GB `crunchtools-hook-cache` volume that is
  supposed to be big and would bury the signal.

  Reads store metadata through `podman_exec.sh` rather than walking the
  filesystem — about 2s for all four — so it stays in the fast pool without the
  memory spike behind RT #1459. The `Images` row is selected by its `Type`, not
  taken as the first number in the table: reading the volume row by accident
  would treat developer1's 7.26 GB `crunchtools-hook-cache` as images and go
  CRITICAL on a healthy store. `podman_exec.sh` reports failures as
  `EXEC_ERROR:` on stdout and still exits 0, so the text is what decides — an
  absent container is reported as idle, while a dead socket or an unparseable
  table is UNKNOWN rather than silently looking like an idle service. That
  UNKNOWN applies to the alerted services only: a cache we cannot read is
  reported as `unreadable cache:` and leaves the verdict alone, because the
  check already says it does not judge that store.

## [9.4.0] - 2026-11-08

### Fixed
- `check_cloudflare_global.sh` no longer pages on incidents confined to a
  Cloudflare environment this account is not in. "Fedramp Customers have
  Delayed Purges" held the check at WARNING for five hours on 2026-11-08 while
  Cloudflare's own update on it read "Non-fedramp customers are not impacted."

  The component filter could not catch this one. Cloudflare files
  environment-scoped incidents under the ordinary public component names: the
  `components[]` entry was a plain `CDN Cache Purge`, which we do depend on,
  and the `group_id` was the same value every component on the status page
  carries. Nothing in the payload marks the scope, so the only signal is the
  incident name, and that is now matched against `EXCLUDED_SCOPES` before the
  component filter runs.

  Listed there: FedRAMP (Cloudflare for Government is a physically separate
  edge; these four zones are commercial Free plan) and China Network (needs the
  Enterprise add-on). The bar for that list is *categorically impossible for
  this account*, not merely unlikely — regional scope is deliberately excluded,
  because an incident "in Phoenix" still serves our visitors. An out-of-scope
  incident is counted and named in the OK line, so it stays visible without
  waking anyone, and it cannot mask a real incident filed alongside it.

### Added
- Cloudflare `Access` and `Zero Trust` are now alertable components. Re-auditing
  the account against the status page turned up a gap the previous audit
  (2026-09-29) predates: four self-hosted Access applications gate
  `nagios.crunchtools.com`, `learn.fatherlinux.com`, `rt.fatherlinux.com` and
  `dev.rootsofthevalley.org`, created 2026-10-10 and 2026-11-05. An Access
  outage locks us out of Nagios, the wiki and RT, and the check would have
  reported OK straight through it. Incidents land on either component name, so
  both are listed.

  `Zero Trust Dashboard` was considered and left out: losing it blocks policy
  edits, not logins. The rest of the audit confirmed the existing list —
  Email Routing stays off it because mail is MX'd to self-hosted
  `mail.crunchtools.com`, not `route*.mx.cloudflare.net`.

## [9.3.1] - 2026-11-08

### Fixed
- `config-drift-repos-collect.sh` no longer compares a `.gitignore` against its
  rival repo's. A repo's `.gitignore` names build output and editor droppings;
  the one beside a service's config names runtime state that must not be
  committed. They describe different trees and are *meant* to differ, so the
  comparison reported a divergence that could never be resolved — and a WARNING
  nobody can clear teaches the fleet to ignore the check, which is the exact
  failure this one exists to catch. trentina's was the last standing divergence
  on the whole fleet, and it was this.

  Shipped as a release rather than left on master because the drift check
  compares the plugins running on the host against the ones in the **released**
  image, and `latest` only moves on a `v*` tag. Between the merge of #143 and
  this tag, gloval ran the fixed collector while `quay.io/crunchtools/nagios-agent:latest`
  still held the old one, so the agent correctly reported itself as drifted —
  one unpublished plugin, honestly counted. The fix for that reading is the tag.

### Changed
- python-sdlc pre-commit hooks to v0.5.3 (#144).

## [9.3.0] - 2026-11-07

### Added
- `check_deploy_drift.sh` understands `io.crunchtools.deploy=deployer`. A
  container carrying that marker and no auto-update label is counted as
  **deployed by ticket** and is never drift: the deploy robot deploys it with a
  maintenance window, a health probe and one rollback, so "behind what the tag
  points at now" is its normal state, and `check_deployer.sh` is what watches
  it. Without this, every service onboarded into the robot's registry would
  have become a permanent `unmanaged` WARNING telling somebody to undo the
  change — and a standing WARNING teaches the fleet to ignore a check, which is
  the exact failure this one was written to catch.

  A **positive marker on the container**, not another image-name exception in
  the collector. The registry grows one service at a time, and a check that
  needed editing for each one would be a check that was wrong in between.
- A `contested` verdict: both `io.crunchtools.deploy=deployer` and
  `io.containers.autoupdate=registry` on one container. That is the likely
  mistake when onboarding, and it is worse than either mechanism alone —
  auto-update would put an unverified image live behind the robot's back, and
  the robot would roll back something auto-update had just installed. Reported
  as drift rather than silently resolved in favour of one of them.
- `STUB_SOCK_ALT_RC` in the plugin tests, which is what lets a **listing that
  succeeds** and an **inspect that fails** be told apart. The previous stub
  failed both at once, so the collector took the keep-the-whole-previous-file
  path and the per-container retention of the two new kinds could not be tested
  at all. Both new tests were checked by breaking the line they cover.
- The OK headline says how many containers are deployed by ticket. That count
  returning to zero on its own is the marker having been dropped from a unit,
  which is the one way this could quietly stop being true.

## [9.2.0] - 2026-11-07

### Added
- `config-sources.conf` maps the last six services the check could reach but
  nobody had claimed: the three `developer` seats, both GHA runners,
  `mcp-gitlab`, and `selinux-local` as an explicit `none`. All six were
  answered by the file's own rule — read the unit and see what image it pulls —
  and the seats' `identity/CLAUDE.md` files were edited this week with nothing
  comparing them to anything. `linux-mcp-server` was left out of that pass
  because it was being added to `/srv` at the time; it is mapped below.
- `linux-mcp-server` mapped to `rhel10-bootc-server`, completing the set. The
  bootc image ships its unit and its authorization policy, because `/usr` is
  read-only on an image-mode host, so that is the repo a stale reference copy
  would hide in — "ask what ships the service", as the file itself puts it.
  Its nftables fence and env file are host-only and live in `/srv` alone
  (RT #1568).

## [9.1.0] - 2026-11-07

### Added
- `config-sources.conf` maps `deployer.crunchtools.com` to the `deployer` repo.
  It was UNMAPPED, so nothing was comparing the deployed unit and registry
  against a second git home — and "we looked and found nothing" reads the same
  as "nobody ever looked".

### Fixed
- The reference copies under `deploy/` match what is deployed again.
  `deploy/nagios/deployer.cfg` still carried the 8.x `notes` text, which
  described verdicts 9.0.0 changed, and
  `deploy/systemd/nagios-agent.crunchtools.com.service` was missing the
  read-only deployer-state mount the Deployer check needs. Both were reported
  as divergent by this repo's own config-drift check, which is the check doing
  its job.

### Added
- A **Linux MCP Server** service on gloval (RT #1568), watching the
  linux-mcp-server unit that is the Josui Prime agent's administration path
  into that host. It reuses `check_service_running.sh` rather than adding a
  plugin: the unit is `Restart=always`, so a broken one loops between
  auto-restart and activating and never reaches `failed` — the gap that check
  already exists for.

  The failure most likely in practice is not a crash. The unit has a
  `ConditionPathExists` on an env file that is per-host and deliberately
  absent from the bootc image, and its preflight refuses to start without the
  nftables fence loaded, so either one going missing leaves the unit
  `inactive` — CRITICAL here, and the service notes say where to look.

  No port check: that port admits only the gateway's address, and probing it
  from the monitoring container would mean widening the rule for a root
  script-execution service.

## [9.0.0] - 2026-11-07

### Changed
- **BREAKING (constitution: Plugin Interface Versioning).** `check_deployer.sh`
  gives a different verdict for three of the deployer's outcomes — `refused`,
  `rolled-back` and `rollback-failed` — and the Nagios service definition on
  the server is a consumer of that interface, so this is a MAJOR bump.

### Fixed
- The `rollback-failed` CRITICAL now requires **the hold that failure placed**
  to still stand, matched by unit name against the status file's own `hold`
  lines. "Any hold at all" would keep one service's stale failure critical
  because another happened to be held. A
  rollback that does not verify always places a hold, so a `rollback-failed`
  outcome with nothing held means a person has already cleared it — and since
  the status file is rewritten only when a ticket runs, the alert otherwise
  stayed CRITICAL until the next deploy. Measured the first time a rollback was
  reported, with the service up and healthy on its previous image.
- `check_deployer.sh` no longer warns about a ticket the deployer **refused**.
  A refusal is a decided state — the deployer exits 0 for one, and the stalled
  ticket owned by whoever filed it is the channel — so warning here contradicted
  that contract. It also outlasted the problem: the status file is rewritten only
  when a ticket runs, so a refusal on Tuesday was still amber on Friday with the
  ticket long since dealt with. A `rolled-back` outcome is likewise left to the
  hold, which is live state and already reported. `could-not-run` and a
  truncated file still warn, because nothing else reports those — and so does
  an outcome this check has never heard of, because the list is named the other
  way round. A list of outcomes to *warn* about would read an outcome added to
  the deployer later as healthy, and the two drifting apart silently is the
  thing to avoid.

## [8.5.0] - 2026-11-07

### Release note

8.1.0, 8.3.0 and 8.4.0 were written up here but never tagged and never
published: the newest tag was `v8.2.0` and the newest image on Quay was
`8.2.0`, so gloval had been running two minor versions behind what this file
claimed was released. `:latest` only moves on a stable `v*` tag (see
`build.yml`), and a push to master builds without moving it, so documenting a
release was not releasing one.

8.5.0 is therefore the first published image that contains the 8.3.0 and 8.4.0
work, alongside everything below. Those sections are left where they are rather
than renumbered — they describe real changes, and rewriting history here would
make the git log and this file disagree.


### Fixed

- **`backup-freshness-collect.sh` / `check_backup_freshness.sh`**: a backup that
  is still uploading is no longer reported as MISSING (RT #1566).

  A weekly Servers run moves ~15 GiB in ~144,000 files and takes over ten hours,
  so for most of every Saturday the destination is half-written. The collector
  had no idea the job producing its inputs was still running, so every dump that
  rclone had not reached yet looked exactly like a dump that was gone, and the
  check went CRITICAL every week. It was acknowledged rather than fixed, which
  is the worse outcome: the backup alarm had been trained to mean nothing.

  The collector now asks podman whether a run of its own mode is up, and reports
  `result=inflight` instead of `missing`. `inflight` joins the existing
  "could not look this time" path, so an item with history shows its last real
  answer; only an item with no history reaches the plugin, which ranks it
  UNCHECKED rather than CRITICAL.

  systemd cannot answer this — to the agent container `systemctl` is a chroot —
  but the podman socket is already mounted and `curl` is already in the image.
  The guard matches the container name *prefix* (`pbs-server-*`,
  `pbs-personal-*`) rather than deriving a name per rotation: the units name
  their containers inconsistently (`pbs-server-weekly` but
  `pbs-server-monthly-1`), and a rotation added later inherits the guard.

  A podman socket that cannot be read yields `unknown`, which deliberately falls
  through to MISSING. A read that failed must not masquerade as a guard that
  answered "nothing is running" — the same mistake as treating an empty
  `ExecCondition` as "no guard configured". Hiding a backup that is really gone
  is worse than showing a false CRITICAL.

  Mode-isolated: a personal rotation running does not excuse a missing server
  dump, or the reverse.

  The guard itself lives in `collector-lib.sh` as `cl_producer_running`, so any
  collector whose inputs are written by a long job can use it, and so it can be
  unit-tested directly: through the plugin, `unknown` and `no` cannot be told
  apart (both fall through to MISSING by design), which is exactly where a
  regression would hide.

### Added

- **`check_deployer.sh`**: the holds the deploy robot
  ([crunchtools/deployer](https://github.com/crunchtools/deployer)) has placed,
  and whether anything still honours them. OK with no holds and the auto-update
  hold guard installed; WARNING for a hold or a failed last run; CRITICAL when a
  hold exists but `ExecCondition` on `podman-auto-update.service` is empty, when
  a hold has stood 24h, or when a rollback failed to verify; UNKNOWN when the
  state directory cannot be read.

  A hold with no guard is CRITICAL rather than WARNING because it reads as
  protection that is not there: the image that was rolled back goes live again
  at the next auto-update.

  It reads the host — the hold files and one systemd property — and deliberately
  *not* the deployer's own status file, which is written only when a ticket runs.
  A hold placed last week sits under a `generated=` from last week too, so that
  file's age says nothing about whether a hold is current. Everything it reads
  is local, so this is a plain check and not a collector (constitution XVI).

  Registered as `check_deployer` in the host NRPE pool (`nrpe-host.cfg`, port
  5666 -- it reads the host, not a container) with the Nagios service
  definition in `deploy/nagios/deployer.cfg`.

## [8.4.0] - 2026-11-06

### Fixed

- **`check_personal_backup_freshness.sh` no longer expects `Projects`.** pbs
  2.3.1 (crunchtools/pbs#45) dropped `pcloud:/Projects` from the Files rotation,
  because Scott moved `~/Projects` to a one-way backup at
  `pcloud:Backups/Servers/breetai.dc2.crunchtools.com/Projects` on 2026-11-04 —
  two-way sync had been writing `.conflict` copies into live git repositories —
  so the source folder no longer exists and rotating a backup is redundant.

  This check kept the name in its own hardcoded `DIRECTORIES`, which is the
  worse half of the bug: pbs will never write that marker again, so the marker
  can never be refreshed, and the rotation would have gone STALE and stayed
  CRITICAL with nothing anyone could do about it. A permanent CRITICAL on a
  backup check is the one that must never be allowed to stand.

  The header now says in as many words that this list has to track `pbs.sh`'s
  `directories`, because the two files have no other link and nothing else
  would catch the next divergence. RT#1556

## [8.3.0] - 2026-11-06

### Changed

- `deploy-drift-collect.sh` ignores `quay.io/crunchtools/developer`, the way it
  already ignores `pbs`. The three developer seats on gloval carry no
  `io.containers.autoupdate=registry` label on purpose (RT #1556, Scott
  2026-11-06): an agent in one runs jobs that take hours, and auto-update
  restarting it at 03:00 destroys the work. A release reaches a seat when the
  seat is restarted deliberately, between jobs.

  Reported as `unmanaged`, that is a WARNING nobody can ever clear — and a
  standing WARNING is how a fleet learns to ignore a check. This one exists
  because three MCP servers sat releases behind with every check green
  (2026-10-24); the way to lose that is to leave it crying wolf. RT#1556

## [8.2.0] - 2026-11-06

### Changed

- `check_agent_egress.sh` is replaced by `check_agent_gateway_stale.sh`. The
  first one counted ESTABLISHED connections from an agent container to its
  gateway's client egress and called zero CRITICAL. That is the wrong signal:
  Claude Code's Remote Control polls — a connection roughly every thirty to
  two hundred seconds, gone in about a second — so a healthy idle agent has
  none at almost any instant. Measured on gloval 2026-11-06: one hit in ten
  samples over two minutes, and a CRITICAL for a Josui Prime that was polling
  normally.
- The replacement watches the failure that is real, documented and silent:
  when the gateway restarts, every client's session dies with it and the agent
  keeps running with no tools. Comparing the two containers' start times says
  so exactly, with no sampling to race against and a grace (900s) so a
  deliberate gateway-then-agents restart does not page while it runs. RT#1556.

### Fixed

- `check_deploy_drift.sh` used `sort -t=`, which uutils reads as an empty
  separator; 13 tests failed on it the first time CI ran on an ubuntu-26.04
  runner. `sort -t '='` is right for both implementations. RT#1558.
- The plugin test harness can answer two different socket URLs in one run
  (`STUB_SOCK_TOKEN`, `STUB_SOCK_ALT`), which a plugin that inspects two
  containers needs.

## [8.1.0] - 2026-11-06

### Added

- `check_agent_egress.sh`: an agent container that holds no connection to its
  gateway's client egress is CRITICAL. On 2026-11-05 josui.crunchtools.com ran
  for nineteen hours with a live `claude remote-control` holding zero sockets
  after the gateway restarted — container up, process up, unit happy, agent
  gone from the operator's session list, and nothing watching the one thing
  that would have said so. It reads the container's own
  `/proc/<pid>/net/tcp` through `--pid=host` rather than exec'ing into it, and
  it is UNKNOWN rather than OK whenever it cannot tell. RT#1556.

## [8.0.0] - 2026-11-04

### Changed

- **BREAKING**: `check_ping_cloudflare` verdict thresholds raised from
  `-w 5.0,20% -c 50.0,60%` to `-w 25.0,20% -c 100.0,60%`. The warning sat
  exactly on the normal latency: measured baseline from gloval to 8.8.8.8 is
  min/avg/max 4.948/5.018/5.489ms with mdev 0.130 over 20 packets, so the check
  warned essentially always — 912 alerts since 2026-08-23, every one reporting
  0% packet loss. A monitor that is always yellow trains you to ignore it.
  Warning is now 5x normal, which still catches real degradation. Packet loss
  thresholds are unchanged at 20%/60%. MAJOR per the constitution, which
  requires it for any change to an existing check's verdict thresholds.

## [7.4.0] - 2026-11-04

### Added

- `check_service_running.sh <unit>`: a long-running service that restarts
  itself. With `Restart=always` a broken service loops instead of failing, so
  `check_systemd_units.sh` stays green; this is CRITICAL on auto-restart,
  failed or stopped, WARNING while starting, and reports `NRestarts`. Wired as
  `check_gha_runner_cached` / `check_gha_runner_uncached` for the two GitHub
  Actions runners on gloval (`deploy/nagios/gha-runner.cfg`), with retries that
  absorb a one-job runner's restart between jobs.
- `check_container_opendkim.sh` watches the DKIM signing milter in the mail
  relay. The relay runs with `milter_default_action = accept`, so a dead
  signer does not stop mail, it sends it unsigned — postfix logs a successful
  delivery either way and the first sign of trouble would be our mail landing
  in spam weeks later. CRITICAL when the signer is gone or when it is up but
  not accepting connections on 127.0.0.1:8891, since the second fails exactly
  as silently as the first. Both probes run in one exec. Registered as
  `check_opendkim_mail` in the container pool (RT #1548).

### Fixed

- `podman_exec.sh` built the exec request body by hand and escaped only
  backslashes and quotes, so a literal newline or tab in an argument went
  straight into the JSON string and made the body invalid. The API refused
  the exec and the only symptom was `EXEC_ERROR: Cannot create exec in
  container <name>`, which reads like a container problem rather than a
  quoting one. Newlines and tabs are now escaped, with a test asserting the
  body parses (RT #1548).
- `check_container_opendkim.sh` sent its probe as a multi-line string and hit
  exactly that, returning UNKNOWN against a healthy signer. The probe is one
  line now, so the plugin does not depend on the fix above.

### Changed

- `deploy/nagios/registry-drift.cfg` attaches the check to gloval, where it
  is deployed since the lotor cutover (RT #1546).
- Every check now runs through python-sdlc (constitution v1.30.0), kept
  current at v0.3.7.

## [7.3.2] - 2026-11-03

### Fixed

- Directory sentinels (`mode=dir`) picked the newest `*.sqlite*` file, which
  is usually a `-shm` or `-wal` sidecar a live database touches on every open.
  On gloval, takeda-db judged its 32K `openclaw.sqlite-shm` and failed the
  50K floor while the database itself was fine. Those sidecars and `-journal`
  files are now skipped.

## [7.3.1] - 2026-11-03

### Fixed

- `backup-freshness-collect.sh` read `pcloud:Backups/Servers/lotor.dc3.crunchtools.com`
  whatever host it ran on, so after the cutover gloval's Backup Freshness
  judged lotor's frozen rotations and went CRITICAL while gloval's own backup
  was fine. The path now comes from the host's FQDN (`HOST_FQDN`, default the
  kernel hostname); `BASE` still overrides it (RT #1546).

## [7.3.0] - 2026-11-03

### Added

- "SELinux Drift" check (`check_selinux_drift.sh`, collector
  `selinux-drift-collect.sh`): warns when the host's local SELinux booleans,
  ports or file-context rules differ from the git-tracked
  `/srv/selinux-local/config/local.semanage` that `selinux-local.service`
  re-applies at boot. Those settings live in `/var/lib/selinux`, outside the
  `/etc` backup, and hand fixes made on lotor were lost on gloval (RT #1546).

## [7.2.4] - 2026-11-03

### Fixed

- `check_container_httpd_internal.sh` probed the first address in the
  container's JSON. A container also joined to an internal network (RT and
  the wiki on gloval, RT #1546) listed an address the host cannot route to,
  so the probe timed out and the check went CRITICAL. It now takes the first
  address on a local bridge.

## [7.2.3] - 2026-11-03

### Changed
- Server deploy files follow the move from lotor to gloval (RT #1546): the
  Nagios host is `gloval.dc4.crunchtools.com`, the gateway check pings
  Hetzner's 88.198.7.193, and host metrics read `nvme0n1` and `enp6s0`.

### Added
- `deploy/nagios/lotor-mail.cfg`: lotor keeps `mail.crunchtools.com` until
  Hetzner lifts gloval's outbound port 25. Nagios on gloval reaches lotor's
  NRPE agents through the mail tunnel on 10.88.0.1:15666 and :15667.

## [7.2.2] - 2026-11-01

### Fixed
- Deploy drift ignores `quay.io/crunchtools/pbs`. Its containers are one-shot
  backup jobs that pull their own image, so the unmanaged warning fired on every
  long backup and its fix, the autoupdate label, could restart a job mid-backup.

## [7.2.1] - 2026-10-29

### Fixed
- `deploy/nagios-agent/nrpe-ctr.cfg` and `registry-images.conf` drop the
  mcp-gw-work, mcp-jira, mcp-workboard and mcp-slack checks, matching what
  lotor has deployed since that stack was decommissioned (clears the
  Config drift cross-repo warning).
- Registry drift asks Quay for the release tag by name (`specificTag`). The
  tag listing is newest first and capped at 100, so rotv, which tags every
  commit, pushed 1.65.5 off the page and read as MISSING while Quay had it.

## [7.2.0] - 2026-10-26

### Changed

- Deploy drift and Config drift cross-repo, the last two checks that made
  outside calls on every run, now use the collector and status-file pattern
  (constitution XVI). `deploy-drift-collect.sh` lists and inspects the running
  containers and asks Quay where each tag points; `config-drift-repos-collect.sh`
  takes the fingerprint from `nagios-agent.crunchtools.com` and clones the
  rival repos, caching each repo's tree so a failed clone keeps the last good
  one. Both run in `nagios-agent-ctr.crunchtools.com`, kicked at 30m and stale
  at 3h against the 60m check_interval. The checks keep their arguments,
  thresholds and first lines: deploy drift applies `grace_hours` when it
  judges, config drift keeps the divergence ratchet and the CRITICAL ladder.
  Perfdata gains `collected_age`.

## [7.1.1] - 2026-10-26

### Fixed

- `google-oauth-collect.sh` rejected credential paths containing `@`, which is
  how the production files are named, and skipped those lines silently: both
  "OAuth refresh token" checks sat at "not collected yet". `@` is allowed, and a
  conf line the collector rejects is now reported as UNKNOWN (BADCONF) instead
  of skipped. The test fixture uses account-named paths.

## [7.1.0] - 2026-10-26

### Added

- Collectors for every check that called an outside API on each run
  (constitution XVI). Each one does its reads with per-item timeouts inside a
  budget, keeps an item's last good answer when a read fails, and writes a
  status file atomically to `/var/lib/nagios-agent`. The checks judge the file
  with their old thresholds, arguments and first-line format, start the
  collector detached in `nagios-agent-ctr.crunchtools.com` when the file is
  past REFRESH, and go UNKNOWN "collector stale" only when it is missing or
  past STALE. Perfdata gains `collected_age`.
  - `cloudflare-collect.sh`: all zones in `cloudflare-zones.conf` plus the
    status page, one pass. `check_cloudflare_status.sh`,
    `check_cloudflare_global.sh`. REFRESH 2m, STALE 10m.
  - `quay-collect.sh`: every `check_quay_staleness.sh` image in the NRPE
    config, plus any image a check names when it kicks.
    `check_quay_staleness.sh`. REFRESH 2m, STALE 10m.
  - `registry-drift-collect.sh`: the git, Quay and GHCR reads moved out of
    `check_registry_drift.sh` unchanged, with a 120s budget. The 4h drift
    grace is measured when the file is judged. REFRESH 30m, STALE 3h.
  - `google-oauth-collect.sh`: the refresh-token exchange for every account in
    `google-accounts.conf`. A token Google rejected stays CRITICAL while
    nothing can be read. `check_google_oauth.sh`. REFRESH 2m, STALE 10m.
- `collector-lib.sh`: lock, atomic publish, status load, age gate and
  detached kick, shared by all five collectors and their checks. The backup
  collector and checks from 7.0.0 now use it too, with unchanged output.
- The ctr agent unit bind-mounts `/srv/nagios-agent.crunchtools.com/data` at
  `/var/lib/nagios-agent`, the same directory the host agent uses.

### Fixed

- `check_cloudflare_status.sh` had been blind since Cloudflare sunset the
  Zone Analytics REST API: every call returned error 1015 and the plugin read
  it as zero traffic, so every zone reported "OK - no traffic in last 24h".
  The collector reads the GraphQL Analytics API instead, and an API error is
  UNKNOWN, not OK.
- The Cloudflare token is passed to curl in a 0600 config file, never in its
  argv, which `--pid=host` makes readable from anywhere on the host.
- `registry-images.conf` listed mcp-workboard twice, so Registry drift
  counted 56 images where there are 55. The collector also drops duplicate
  lines.

### Unchanged

- `check_postiz_tokens.sh` (OAuth token expiry) stays live: it reads Postiz's
  own database through the podman socket and makes no outside call.

## [7.0.0] - 2026-10-26

### Changed

- **Breaking (thresholds):** drift checks get a 4h grace, so a deploy in
  progress is no longer an alert. The age of the drift is computed statelessly
  from mtimes and the verdict is OK "drift <age>, within grace (warn after
  4h)" until any drifted item is older than WARN (14400s), then WARNING as
  before.
  - `check_git_drift.sh`: default WARN raised from 3600 to 14400; CRIT stays
    24h.
  - `check_unit_drift.sh`: was WARNING on any difference. Each unit is dated by
    the newer mtime of its /etc and /srv copies (an unbacked unit by its /etc
    copy); `srv-drift-collect.sh` emits the oldest as `unit_drift_since`. `WARN`
    env overrides.
  - `check_plugin_drift.sh`: was WARNING on any difference. Each differing
    plugin is dated by its mtime in the scripts dir, a removed one by the dir's
    mtime. `PLUGIN_DRIFT_WARN` overrides.
  - `check_registry_drift.sh`: a tag missing from a registry is dated by
    Quay's `start_ts` when only GHCR lags, else by the Created time of a local
    image carrying the tag, else counts as aged. Untagged repos still warn at
    once. `REGISTRY_DRIFT_WARN` overrides; perfdata gains `in_grace`.
- **Breaking (behaviour):** `check_backup_freshness.sh` and
  `check_personal_backup_freshness.sh` no longer read pCloud. They judge the
  status files `backup-freshness-collect.sh` writes, with the same thresholds,
  and go UNKNOWN only as "collector stale": the file is missing or over 2h
  old, or a sentinel has not been read for 2h. Perfdata gains
  `collected_age`.
- `deploy/nagios/*.cfg`: every NRPE service uses the new pool templates,
  `nrpe-fast-service[-slow]` for `check_nrpe_command!` and
  `nrpe-ctr-service[-slow]` for `check_nrpe_ctr!`, matching lotor.
- `deploy/nagios/git-drift.cfg` and `unit-drift.cfg` are now carried here. The
  git-drift header no longer says it reads a status file from
  `srv-git-drift.timer`; that timer has been gone since RT #1477. Stale
  comments in `nrpe-host.cfg` are fixed to match.

### Added

- `backup-freshness-collect.sh servers|personal`: does the pCloud reads with a
  120s budget (30s a listing, one retry; 60s for the markers) and writes the
  status file atomically to `/var/lib/nagios-agent`. A listing that times out
  keeps the previous real answer, so one slow read is no longer an alert. A
  flock stops overlapping runs. No timer: the checks start it through the new
  `podman_exec.sh --detach` when their status file is over 20m old, so the
  Nagios check interval is the clock (constitution XVI).
- The host agent unit bind-mounts `/srv/nagios-agent.crunchtools.com/data` at
  `/var/lib/nagios-agent`, so the status files survive a container recreate.
  The image creates the directory.

### Fixed

- `check_container_postgres.sh`: `pg_isready` exiting 127 (not in the image)
  is UNKNOWN "pg_isready missing from image <container>", not CRITICAL "not
  accepting connections".

## [6.5.0] - 2026-10-26

### Added

- `check_deploy_drift.sh` and the Deploy drift service: WARNING when a running
  quay.io/crunchtools container is "unmanaged" (no `io.containers.autoupdate`
  label, so releases never land) or "stale" (running digest behind its Quay
  tag past a 30h grace, so auto-update is not applying). Registry drift checks
  that a release reached the registries; this checks that it reached lotor.
  On first run it found mcp-systemd, mcp-podman, mcp-notebooklm and postfix
  unmanaged.

## [6.4.1] - 2026-10-26

### Fixed

- `registry-images.conf`: the openclaw image maps to the `openclaw` repo again.
  The takeda seat rename changed its first field, which is the GitHub repo, to
  `takeda`, a repo that does not exist, so Registry drift went UNKNOWN.
- Nightly Dump Freshness no longer watches data-collector's `collector.db`. The
  collection was a six-run Hermes job that ended 2026-10-22, so the database
  stops changing by design and the check went CRITICAL two days later.

## [6.4.0] - 2026-10-25

### Added

- `check_trove_run.sh`: WARNING when the run's vision provider ran out of
  credit (`vision_out_of_credit`, mcp-trove 1.0.2+), with the number of files
  deferred, so the key gets topped up.

## [6.3.0] - 2026-10-25

### Added

- `check_trove_run.sh` (RT #1542): reads the summary mcp-trove 0.10+ writes
  after each nightly `--index` run. CRITICAL when it is missing, over 36h old
  or its status is not `ok` (aborted path, unmounted or hung source, backup or
  quick_check failure), naming the problem; WARNING when over 5% of files
  failed, the vision budget was spent or no recent backup is recorded. sqlite3
  parses the JSON in memory, since the image has no jq or python. `:5666`
  pool, as `check_trove_run`; service `Index run` in
  `deploy/nagios/mcp-trove.cfg`.

## [6.2.0] - 2026-10-24

### Added

- mcp-trove monitoring (RT #1542). The usual MCP triple, `check_tcp_8032`,
  `check_ctr_run_mcp_trove` and `check_ctr_mem_mcp_trove`, plus two checks for
  what trove depends on, defined in `deploy/nagios/mcp-trove.cfg`:
  - `check_fuse_mount.sh` + `mount-probe-collect.sh`: CRITICAL when
    `/var/mnt/pcloud` is not a mountpoint in the host namespace, or a listing
    of `Documents` fails, times out or comes back empty. The collector runs as
    root through `podman_exec.sh` and walks `/proc/1/root`, so the agent unit
    gains no new mount. `:5667` pool, as `check_trove_pcloud_mount`.
  - `check_sqlite_rows.sh`: CRITICAL when a SQLite database or table is
    missing or holds fewer than N rows. Opens the file with a `mode=ro` URI
    through the read-only `/var/srv` mount, as nrpe. `:5666` pool, as
    `check_trove_index`.
- The image installs `sqlite` (the CLI) for `check_sqlite_rows.sh`.

## [6.1.1] - 2026-10-24

### Fixed

- The `check_backup_freshness` "all fresh" test was flaky: the rclone stub
  dated files exactly one day before its own clock, so a later wave could
  read 0d. It failed the v6.1.0 tag build, so v6.1.0 has no image; 6.1.1
  carries the same plugin code.

## [6.1.0] - 2026-10-24

### Changed

- `check_backup_freshness.sh` names the worst sentinel on its first line
  (`BACKUPS CRITICAL - rt-db: MISSING (...) [+N more]; Weekly-1 13/14 fresh
  ...`), because notifications carry only that line. Perfdata gains
  `unknown=` and `elapsed=`. UNKNOWN now outranks WARNING.

### Fixed

- Backup Freshness flapped CRITICAL/UNKNOWN on slow pCloud listings (RT
  #1543). The run now sits inside a 12s deadline (`BUDGET`, `PROBE_T` 6s per
  listing), under NRPE's 15s `command_timeout`. Sentinels reached with under
  2s left report UNCHECKED instead of timing out the whole check. rclone's
  exit code is captured instead of lost in a pipe, so a timeout or listing
  error is UNKNOWN after one retry, and only "not found" (exit 3/4) or an
  empty listing is CRITICAL MISSING.

## [6.0.0] - 2026-10-24

### Changed

- **Breaking:** `check_postiz_tokens.sh` no longer warns on a countdown. It sat WARNING on
  LinkedIn's 60-day token for weeks with nothing to act on, because the Postiz
  UI only offers the reconnect once the channel is broken. It now goes
  CRITICAL only when a token has expired or Postiz sets `refreshNeeded`; days
  left stay visible in the OK output. The `warn_days`/`crit_days` arguments
  are gone, and `nrpe-ctr.cfg` drops them.

### Removed

- Factory watchdog monitoring: `check_factory_status.sh`,
  `check_factory_health.sh`, `deploy/nagios/factory-status.cfg`, the
  `check_ctr_run_/check_ctr_mem_factory_crunchtools_com` and
  `check_procs_factory_watchdog` commands, the factory status bind mount, and
  the `factory` entries in `registry-images.conf` and `config-sources.conf`.
  factory.crunchtools.com is decommissioned: it spent ~5,200 GitHub REST
  calls an hour and its checks are covered by per-repo CI, constitution
  fleet-drift, Ashigaru and the weekend report. The three Quay staleness
  services move from `factory-host` to `lotor.dc3.crunchtools.com`.

## [5.2.0] - 2026-10-19

### Added

- `check_tig_trends.sh`: WARNING while a Grafana trend rule fires, with what
  it fired for; UNKNOWN if Grafana cannot be read; never CRITICAL. The trend
  rules no longer page, so this is where they surface (crunchtools/tig#22).
  Every branch is exercised through `check_nrpe` on lotor before release.

## [5.1.2] - 2026-10-18

### Fixed

- Map bridge-rcs-josui to the trentina repo and conduit-josui to none, and
  add their container checks to the deployed nrpe-ctr.cfg, so the config
  drift check covers Josui Prime's RCS channel (RT #1531).

## [5.1.1] - 2026-10-18

### Fixed

- Map bridge-rcs-kagetora and bridge-rcs-takeda to the trentina repo, so the
  config drift check covers them instead of reporting them unmapped (RT #1529).

## [5.1.0] - 2026-10-17

### Added

- `check_ondemand_unit.sh <socket> <service> [path]` checks a service that
  runs only on demand. It is CRITICAL when the socket or path unit that would
  start the service is down, or when the service has failed. It is OK while
  the service is idle or running. It needs host systemd, so it runs in the
  fast pool only. dev.rootsofthevalley.org uses it as its host check.
- `check_container_memory.sh` takes an optional fourth argument, `absent-ok`,
  which reports a stopped container as OK instead of UNKNOWN.

### Removed

- test.crunchtools.com checks (container running, memory, MariaDB, Apache
  internal, PHP-FPM), its backup freshness entry and its config-sources
  mapping. The site was decommissioned (RT #1528).
- mcp-ashigaru checks (container running, memory, zombie processes) and both
  config-sources mappings (`mcp-ashigaru.crunchtools.com`, `ashigaru`). The
  Ashigaru v1 server was decommissioned; the factory now runs as
  claude-code-action workflows on GitHub Actions (RT #1523).

## [5.0.0] - 2026-10-17

### Changed

- **BREAKING:** `check_container_restart.sh` reports a clean restart as OK.
  Inside the crit window it reads the replaced container's `die` event from
  the podman events API over the socket it already uses. It stays CRITICAL on
  an OOM kill, an exit other than 0 or 143, more than three deaths in the hour
  before the start, or when no die event can be read. Over the previous month
  the uptime-only verdict sent about 78 pages to Hermes, nearly all of them
  deploys. The warn default is now 0, and both NRPE pools pass `300 0`.
- **BREAKING:** `check_procs_total` is now `-w 2000 -c 2500`, up from 900/1500.
  Healthy bursts peaked at 1747, and once at 1921. They paged 7 times against
  1500, and the 900 WARNING line flapped 301 times.

### Fixed

- `check_container_restart.sh` rejects container names outside
  `[A-Za-z0-9_.-]`, because the name now goes into a JSON filter.

## [4.3.1] - 2026-10-17

### Fixed

- The repo carries the mcp-workboard checks (container running, memory, port
  8031, registry drift) that were deployed on lotor but never committed, which
  kept the cross-repo config drift check at WARNING. config-sources.conf maps
  dev.rootsofthevalley.org, josui, mcp-rhhi and mcp-workboard to their repos.

## [4.3.0] - 2026-10-17

### Changed

- The Hermes checks run their probes inside the Kagetora container over the
  podman exec socket. `check_hermes_exec.sh` sends `check_hermes_platforms.py`
  or `check_hermes_context.py` in and runs it with the container's python3, so
  the 0700 data dir never leaves its container. They replace
  `check_hermes_probe.sh` and lotor's hermes-probe.timer: Crunchtools schedules
  live in Hermes or Nagios, and Hermes cannot watch itself. An exec that cannot
  run is still CRITICAL. (#63)

### Fixed

- The context check reports UNKNOWN when its database query fails. The bash
  probe suppressed sqlite3 errors, so a failed query read as "no open session",
  which is OK.
- A Matrix sync stop no longer lowers `platforms_ok` a second time when Matrix
  was already counted as failed.
- Registry drift no longer flags `mcp-ashigaru` and `mcp-ashigaru-agent-claude`.
  ashigaru v2.0.0 stopped publishing container images, so every new ashigaru
  tag showed as missing from both registries.

## [4.2.0] - 2026-10-08

### Added

- Container running and memory checks for `kagemusha.crunchtools.com`, and its
  directory in `config-sources.conf` (it runs the openclaw image).

## [4.1.0] - 2026-10-08

### Added

- `check_nightly_dump` also watches data-collector's `collector.db`, written
  by a daily timer on the host. A failed run already shows as a failed unit;
  this catches the timer that never fires.
- data-collector in `config-sources.conf` and `registry-images.conf`, so the
  config, registry and Quay checks cover it.

## [4.0.0] - 2026-10-08

MAJOR per the constitution: a verdict threshold on an existing check changed.

### Fixed

- `check_procs_total` on lotor warns at 900 again; CRITICAL stays at 1500.
  3.0.0 raised both lines on the belief that WARNING notifies. It does not:
  the only contact takes CRITICAL alone, so the higher warning line stopped
  no page and hid an RT #1513-sized leak (600 to ~1,100 processes) behind an
  OK.

## [3.0.0] - 2026-10-07

MAJOR per the constitution: a verdict threshold on an existing check changed.

### Changed

- `check_procs_total` on lotor loosened from 900/1100 to 1300/1500. Transient
  bursts to ~1,250 processes with every service healthy paged CRITICAL on
  2026-10-07; the baseline is still ~600. A leak the size of RT #1513 (~500)
  no longer alerts on this check.

## [2.1.0] - 2026-10-06

### Added

- `check_personal_backup_freshness`: age and exit status of each personal
  pCloud rotation (Documents, Downloads, Autosync, Projects in Weekly-1,
  Monthly-1 and Monthly-2), read from the markers `crunchtools/pbs` 2.0.0
  writes to `pcloud:Backups/Rotations/`. One rclone call for all twelve. WARN
  9d / CRIT 16d weekly, 70d / 100d monthly; a missing marker or a non-zero
  rclone exit is CRITICAL (crunchtools/pbs#16). NRPE command and service
  definition under `deploy/`.

### Fixed

- `check_backup_freshness.sh` breaks a tie between equal mtimes on size
  numerically. A lexical sort picked a 90 KB database over an 8 MB one and
  reported it too small.
- `check_registry_drift.sh` asks GHCR for up to 10,000 tags. The default page
  of 100 hid the newest tag of an image with 108.

### Changed

- mcp-trentina is now trentina (repo, image, service directory, container).
  The config-drift service map, the backup-freshness path and the reference
  copies of `nrpe-ctr.cfg` and `registry-images.conf` follow.
- Constitution is now a v1.18.0 manifest: it holds only what is specific to
  this repo; fleet and profile rules apply by reference.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

## [2.0.1] - 2026-10-01

### Fixed

- `check_config_drift.sh` no longer treats a file under `docs/`, `tests/` or
  `examples/` in a project repo as a second home for deployed config. A demo
  fixture named like a production file (`docs/demo/profiles.yaml`) was
  reported as divergent. Reference copies under `deploy/` are still compared.

## [2.0.0] - 2026-10-01

### Changed

- **Breaking:** `check_mcp_feeds_freshness.sh` takes its thresholds in hours,
  not days, and defaults to WARN 6 / CRIT 24 (was 8 / 10 days). The feed crawl
  now runs hourly from a timer on the deploy host and the daily briefing
  depends on it; against that, a day-scale threshold let a four-day crawl
  outage pass without a warning. A caller still passing day values gets
  hour thresholds. `deploy/nagios-agent/nrpe-ctr.cfg` passes `6 24`.

## [1.4.0] - 2026-10-01

### Fixed

- `podman_exec.sh` parses the exec stream's frame headers instead of
  filtering for printable characters. A header's length bytes are often
  printable: 2,609 bytes of output came back as 2,611, with a newline and a
  `1` in front. Every plugin that reads another container's output through
  this helper was exposed whenever the size landed on printable bytes.
- `podman_exec.sh` exits 3 when the API returns no exit code. It used to
  exit 0, so a failed exec looked like a command that printed nothing.

### Added

- `check_tig_freshness`: age of the newest Telegraf point in InfluxDB, asked
  over the Podman exec socket. NRPE commands for the four TIG containers and
  their ports (`crunchtools/tig`, RT #1461).
- `config-sources.conf` maps the four TIG service directories to
  `crunchtools/tig` and adds it as a rival for the Nagios service definitions;
  `registry-images.conf` lists the `tig` image.

### Changed

- `check_procs_total` on lotor tightened from 1100/1300 to 900/1100. The
  baseline fell from ~1,050 to ~600 once exec conmons stopped lingering
  (RT #1513), so the old thresholds hid a 500-process leak.

## [1.3.1] - 2026-09-29

### Changed

- `check_cloudflare_global` counts only the Cloudflare products we use
  (authoritative DNS, CDN/cache, SSL provisioning, WAF, rules, challenges,
  API, dashboard). `Network` is dropped: a regional APAC degradation raised a
  WARNING against zones it never touched. Unused products (Recursive DNS,
  Secondary DNS, Registrar, Always Online) and the non-existent `Zones` are
  gone too.
- `config-sources.conf` maps the Matrix bridge and Conduit services and
  `trentina-demo`, so config drift no longer reports them UNMAPPED.
- `deploy/nagios-agent/nrpe-ctr.cfg` catches up with the deployed copy
  (bridge, Conduit and weston checks).

- `check_container_process_count` and `check_container_httpd_internal` no
  longer open a Podman exec session on every run (RT #1513). Each API exec
  keeps two conmon processes on the host for `exit_command_delay` (300s)
  after it finishes. With checks every minute that came to ~500 standing
  processes on lotor, about half of what `check_procs_total` counted.
  Process counts now come from the `/top` endpoint (the same approach as
  `check_container_zombies`), and a missing container reports UNKNOWN
  instead of a silent 0. HTTP checks curl the container's bridge IP
  directly and fall back to exec only for host-network containers or
  loopback-only ports.

### Added

- `tests/test-plugins.sh`: offline tests for those two plugins with curl and
  `podman_exec.sh` stubbed. They cover parsing, error paths, the exec fallback
  rules and input validation. `test-image.sh` runs them in CI.

## [1.3.0] - 2026-09-20

### Changed

- `check_config_drift` moved from the host NRPE daemon to the container one,
  and now compares five more services (RT #1498).

  It started on the host agent beside `check_git_drift` and `check_unit_drift`,
  which is where it looks like it belongs. That was wrong. It makes ~34 shallow
  clones per run, and against that daemon's 15s `command_timeout` five
  consecutive runs measured 3s, 3s, 11s, 11s and 5s — it had already returned
  `NRPE: Command timed out` once in production. Raising parallelism does not
  help; the cost is per-clone latency, not concurrency. It belongs on the 60s
  daemon beside `check_registry_drift`, which does the same kind of work for
  the same reason.

  Nothing is lost by moving it. The plugin never reads `/var/srv` itself — the
  privileged half runs as root via `podman_exec.sh` inside
  `nagios-agent.crunchtools.com`, which has the tree mounted — and both agents
  bind-mount the same libexec directory, so the plugin is already present in
  both.

- `config-sources.conf`: five services that claimed `none` now name the repo
  that builds the image they actually run.

  `kagetora` runs `quay.io/crunchtools/hermes`; the four WordPress sites run
  the shared `ubi10-httpd-php*` base images. None of those repos carries a copy
  of the deployed config today, which is exactly why they are listed: "we
  looked and found nothing" and "nobody ever looked" are the same green tile
  until somebody adds a file. `none` now survives only where it is true —
  `backups`, which is not a container, and `mcp-lightspeed`, which runs a Red
  Hat image with no Crunchtools repo behind it.

  What a service RUNS is the question, and its systemd unit answers it.


## [1.2.3] - 2026-09-20

### Fixed

- `config-sources.conf` mapped `signal-api.crunchtools.com` to `none`, so
  nobody ever compared it (RT #1498).

  A service's rival is not always the repo of the same name. signal-api is
  deployed as its own service directory, but its unit is shipped by the
  **openclaw** repo, which is what actually runs it. "No repo called
  signal-api" was read as "no rival", and the file went unchecked — while it
  had in fact drifted: the deployed unit joins `openclaw-pod` and runs
  `MODE=normal`, the repo copy published a port and ran `MODE=json-rpc`.

  Ask what ships the service, not what shares its name.


## [1.2.2] - 2026-09-20

### Fixed

- `check_config_drift.sh` called image content a second git home whenever the
  Containerfile `COPY`d it from somewhere other than `rootfs/` (RT #1498).

  "Under `rootfs/`" was only ever an approximation of "baked into the image".
  postiz keeps `ecosystem.config.js` at its repo root and syslog keeps
  `config/rsyslog.conf`, both `COPY`d in and both overridden from `/srv` at
  runtime — the same image-default/host-override pattern as
  `rt/rootfs/opt/rt6/etc/RT_SiteConfig.pm`, which the check already knew to
  ignore. Both were reported as divergent, and both were meant to differ.

  The repo itself has the exact answer, so the plugin now reads it: the skip
  set is `rootfs/` plus every `COPY`/`ADD` source in the Containerfile.
  `COPY --from=stage` is ignored, because that copies out of a build stage
  rather than out of the repo. The clone is blobless, so reading the
  Containerfile lazily fetches that one blob — a few KB per repo, against
  guessing. A repo with no Containerfile is not an error; `rootfs/` alone is
  still a correct answer for it.

  On lotor: divergent 9 → 7, and the 7 that remain are all real.


## [1.2.1] - 2026-09-20

### Fixed

- `check_config_drift.sh` missed every rival a service has beyond the first,
  and `config-sources.conf` now takes a comma-separated list (RT #1498).

  One service directory can be claimed by more than one project repo.
  `/srv/nagios.crunchtools.com/config/services/` is owned by the nagios repo
  AND by this one, which keeps reference copies of its own Nagios service
  definitions under `deploy/nagios/`. With a single-repo map, six deployed
  files were invisible — including `config-drift.cfg`, this check's own
  service definition. Candidates are now scored across every rival at once and
  the single best counterpart wins, so a file claimed twice is still reported
  once. `duplicate` went 6 → 11 on lotor; no new divergences.

- A stray glob in `config-sources.conf` expanded against the working directory
  before validation could reject it.

  The rival list is split on commas by an unquoted expansion, which also means
  pathname expansion. A bare `*` in that column expanded to the names in the
  plugin's working directory — every one of which then looks like a valid repo
  name and gets cloned. The raw field is now rejected whole before it is split.

- The check could hit the host NRPE daemon's 15s `command_timeout` and come
  back as "NRPE: Command timed out" with no detail.

  Thirty-odd anonymous clones at 8-way ran 2s, 3s, 7s and 15s on four
  consecutive tries — the cost is round trips, not CPU, so the variance is all
  network. At 16-way it is a consistent 2s. `CONFIG_DRIFT_TIMEOUT` also drops
  from 25s to 10s: a per-clone bound longer than the daemon's own timeout is
  not a bound at all, because the daemon kills the check before the honesty
  path that would have named the unreadable repo ever runs.

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
