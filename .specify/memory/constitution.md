# Nagios Agent Container Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-09-19
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.14.0
> **Profile:** Container Image

## License

AGPL-3.0-or-later, per universal constitution I.

## Semantic Versioning

Semantic Versioning 2.0.0, per universal constitution II. Version bumps happen
at release time, recorded in `CHANGELOG.md`, and every tag gets a GitHub
Release. A new check plugin is a MINOR bump; a change to an existing plugin's
arguments or verdict thresholds is MAJOR, because the Nagios service
definitions on the server are consumers of that interface.

## Container Registry

Dual-pushed to `quay.io/crunchtools/nagios-agent` (primary) and
`ghcr.io/crunchtools/nagios-agent`, per universal constitution III.

> **Known gap:** `build.yml` currently pushes to Quay only, in a single job,
> with no layer caching and no Trivy scan — three violations of III. Tracked separately in RT #1479.

## Containerfile Conventions

- `Containerfile`, never `Dockerfile`.
- Base image `registry.access.redhat.com/ubi10/ubi-minimal`; `microdnf clean
  all` after package installs.
- Required LABELs: `maintainer`, `description`, plus the OCI `source`,
  `description` and `licenses` labels from III.
- `rootfs/` mirrors the image layout and is applied with a single `COPY
  rootfs/ /`. Plugins are chmod'd with a glob, never an explicit file list —
  an explicit list silently fell five plugins behind and shipped them
  non-executable.

## Testing

CI on every pull request runs a **build test** (the image builds from
`Containerfile`) followed by `tests/test-image.sh`, and both must pass before
merge, per universal constitution VI.

`tests/test-image.sh` is a **smoke test** in two parts: static assertions that
the NRPE binary, its config and each plugin are present at their expected
paths, and a runtime assertion that the daemon actually starts and listens on
its port.

A **security scan** (Trivy) is required by universal constitution III and is
currently missing from `build.yml` — see the Container Registry gap above.

A new plugin MUST be exercised end-to-end via `check_nrpe` from the Nagios
server before it is considered working, including its failure branches — not
just its OK path. See the Check Plugin Rules below.

## Quality Gates

Gourmand (blocking) and Gatehouse (advisory) run on every pull request, per
universal constitution XII. Gourmand runs from
`quay.io/crunchtools/gourmand:latest` via the reusable workflow in
`crunchtools/gatehouse`, never a local install.

`gourmand.toml` exists solely so `gourmand-exceptions.toml` is read, and it
carries the full default `[thresholds]` block verbatim — Gourmand silently
zeroes every threshold when a config file exists without one. Do not tune
those values.

## Secrets and Identifiable Data

This repository is PUBLIC. Per universal constitution XVII, no credentials,
mail addresses, usernames or account-scoped identifiers may be committed here.

Check plugins take an opaque key and resolve the real value from a host config
file under `/srv/<service>/config/`, bind-mounted read-only
into the agent. `check_cloudflare_status.sh <domain>` and
`check_google_oauth.sh <account-key>` are the reference implementations. The
repo carries only `*.conf.example` files showing the shape.

## Image Purpose

NRPE agent for Nagios host-level and container-level monitoring.
Companion to `crunchtools/nagios` (the Nagios Core server). Carries the check
plugins that answer `check_nrpe` requests from the server.

## Base Image

`registry.access.redhat.com/ubi10/ubi-minimal` — the agent needs only the NRPE
daemon, coreutils and curl. No httpd, no language runtime.

## Deployment Topology

Two daemons run from this one image, split 2026-08-26 so slow checks cannot
starve fast ones. Both are documented in `nrpe-dependency.cfg` on the server:

| Port | Unit | Workload |
|------|------|----------|
| 5666 | `nagios-agent.crunchtools.com` | `/proc` reads, filesystem stats, local sockets. Milliseconds. Must keep answering. |
| 5667 | `nagios-agent-ctr.crunchtools.com` | `podman inspect`/`stats` and external API calls. Allowed to degrade. |

Each pool watches the other's container for unexpected restarts
(`check_container_restart.sh`), so neither daemon is the sole witness to its
own death. See RT #1459.

## Check Plugin Rules

Plugins in this repo follow constitution XVI (Monitoring Checks):

- **Standalone.** Every plugin must run directly via `check_nrpe` from the
  Nagios server and give the same verdict Nagios gets. No plugin may depend on
  an MCP server, an LLM agent, or any orchestration layer to decide
  OK/WARNING/CRITICAL.
- **Deterministic.** The verdict comes from a stat call, a date comparison or a
  plain conditional. Never from a model.
- **Credential-free where possible.** Prefer a file mtime, a Unix socket or a
  direct read over an API call needing a token. To read another container's
  state, use the podman exec socket rather than bind-mounting that container's
  SELinux-labeled data.
- **Bounded cost.** A plugin runs on a monitoring agent with a memory cap and
  an NRPE `command_timeout`. Know your plugin's peak RSS and wall time, and
  keep both well inside the budget. RT #1459 was a plugin at 96% of the cap.

## Runtime Configuration

Per constitution XIV, the deployed plugins and `nrpe.cfg` are bind-mounted from
`/srv/<service>/config/` on the host, which shadows the
image's own `/usr/local/nagios/libexec`. The repo is the source of truth;
`/srv` is the deploy target.

> **Known gap:** the deployed `/srv` tree currently carries plugins that are not
> in this repo, and four repo plugins have drifted from what is deployed. Tracked
> separately in RT #1479.
