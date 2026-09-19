# Nagios Agent Container Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-09-19
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.x
> **Profile:** Container Image

## Image Purpose

NRPE agent for Nagios host-level and container-level monitoring on lotor.
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
`/srv/nagios-agent.crunchtools.com/config/` on the host, which shadows the
image's own `/usr/local/nagios/libexec`. The repo is the source of truth;
`/srv` is the deploy target.

> **Known gap:** the deployed `/srv` tree currently carries plugins that are not
> in this repo, and four repo plugins have drifted from what is deployed. Tracked
> separately — see the RT ticket referenced in the README.
