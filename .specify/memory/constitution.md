# Nagios Agent Container Constitution

> **Version:** 1.1.0
> **Ratified:** 2026-09-19
> **Amended:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.22.0
> **Profile:** Container Image

This file holds what is specific to nagios-agent. The fleet rules and the
Container Image profile apply at the inherited version and are checked against
this repo's files by `constitution.yml`. They are not restated here.

## Image Purpose

NRPE agent for Nagios host-level and container-level monitoring. Companion to
`crunchtools/nagios` (the Nagios Core server). Carries the check plugins that
answer `check_nrpe` requests from the server.

## Base Image and Packages

`registry.access.redhat.com/ubi10/ubi-minimal`: the agent needs only the NRPE
daemon, coreutils and curl. No httpd, no language runtime. EPEL 10 supplies
`nrpe` and the stock `nagios-plugins-*`.

- **Podman socket group:** the image bakes in group `podmansock` (GID 1500) and
  adds `nrpe` to it. `podman run --group-add` does not work because nrpe's
  `initgroups()` discards it. GID 1500 is chosen because 997/998 are shared
  with other containers on the host.
- **Released plugin copy:** `/usr/local/nagios/libexec-released` is a pristine
  copy of the shipped plugins, made after the chmod, so
  `check_plugin_drift.sh` can compare against it once `/srv` is bind-mounted
  over `libexec` (RT #1490).
- **Plugin modes:** plugins are tracked 100644 and made executable with a glob
  (`chmod +x .../libexec/*.sh`), never an explicit file list. An explicit list
  silently fell five plugins behind and shipped them non-executable.

## Plugin Interface Versioning

A new check plugin is a MINOR bump. A change to an existing plugin's arguments
or verdict thresholds is MAJOR, because the Nagios service definitions on the
server are consumers of that interface.

## Deployment Topology

Two daemons run from this one image, split 2026-08-26 so slow checks cannot
starve fast ones:

| Port | Unit | Workload |
|------|------|----------|
| 5666 | `nagios-agent.crunchtools.com` | `/proc` reads, filesystem stats, local sockets. Milliseconds. Must keep answering. |
| 5667 | `nagios-agent-ctr.crunchtools.com` | `podman inspect`/`stats` and external API calls. Allowed to degrade. |

Each pool watches the other's container for unexpected restarts
(`check_container_restart.sh`), so neither daemon is the sole witness to its
own death. See RT #1459.

## Check Plugin Rules

- **Standalone.** Every plugin must run directly via `check_nrpe` from the
  Nagios server and give the same verdict Nagios gets.
- **Credential-free where possible.** Prefer a file mtime, a Unix socket or a
  direct read over an API call needing a token. To read another container's
  state, use the podman exec socket rather than bind-mounting that container's
  SELinux-labeled data.
- **Bounded cost.** A plugin runs on an agent with a memory cap and an NRPE
  `command_timeout`. Know its peak RSS and wall time and keep both well inside
  the budget. RT #1459 was a plugin at 96% of the cap.
- **End-to-end before done.** A new plugin is exercised via `check_nrpe` from
  the Nagios server, including its failure branches, before it is considered
  working.

## Plugin Credentials

Plugins that need an account-scoped value take an opaque key and resolve the
real value from a host config file under `/srv/<service>/config/`, bind-mounted
read-only into the agent. `check_cloudflare_status.sh <domain>` and
`check_google_oauth.sh <account-key>` are the reference implementations. The
repo carries only `*.conf.example` files showing the shape.

## Runtime Configuration

The deployed plugins and `nrpe.cfg` are bind-mounted from
`/srv/<service>/config/` on the host, which shadows the image's own
`/usr/local/nagios/libexec`. The repo is the source of truth; `/srv` is the
deploy target.

> **Known gap:** the deployed `/srv` tree carries plugins that are not in this
> repo, and some repo plugins have drifted from what is deployed. Tracked in
> RT #1479.

## Gourmand Configuration

`gourmand.toml` exists solely so `gourmand-exceptions.toml` is read; it needs
no content. Path exclusions go in `.gourmand-exceptions.d/globals.toml` or
`.gitignore`, because Gourmand ignores `excluded_paths` in `gourmand.toml`.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-09-19 | Initial constitution |
| 1.0.1 | 2026-09-25 | Corrected the `gourmand.toml` note |
| 1.1.0 | 2026-10-02 | Manifest under constitution v1.18.0: fleet and profile restatement removed, agent specifics kept |
