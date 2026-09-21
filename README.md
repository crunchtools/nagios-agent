# nagios-agent

NRPE agent for the crunchtools fleet. It is the half of the monitoring
system that actually looks at things: the Nagios server (`crunchtools/nagios`)
decides *when* to ask and *who* to wake, and this image answers the questions.
It ships a UBI 10 minimal base, the NRPE daemon, and the check plugins that read
`/proc`, talk to the podman socket, and probe local services.

Two daemons run from this one image, deliberately. Splitting them keeps a slow
check from starving a fast one — the failure that motivated the split is
documented in `nrpe-dependency.cfg` on the server.

| Port | Unit | Workload | Contract |
|------|------|----------|----------|
| 5666 | `nagios-agent.crunchtools.com` | `/proc` reads, filesystem stats, local socket connects | Milliseconds. Must keep answering — these are the checks that explain an outage. |
| 5667 | `nagios-agent-ctr.crunchtools.com` | `podman inspect`/`stats`, external API calls | Allowed to degrade. |

Each pool watches the other's container for unexpected restarts, so neither
daemon is the sole witness to its own death.

## Capabilities

1. **Host metrics** — CPU with iowait/steal, disk I/O, network throughput and
   memory, read straight from `/proc` with no `sysstat` dependency.
   `check_cpu_stats.sh`, `check_diskio.sh`, `check_net_throughput.sh`,
   `check_mem.sh`.
2. **Container state** — running/not, memory against a cap, and unexpected
   restarts, all via the podman socket the agent already has.
   `check_container_running.sh`, `check_container_memory.sh`,
   `check_container_restart.sh`.
3. **Fleet health** — the factory watchdog's verdict across every repo in the
   org, read from its status file rather than pushed anywhere.
   `check_factory_status.sh`, `check_factory_health.sh`.
4. **Supply chain** — Quay tag staleness and whether an image is being pulled
   from the source you think it is. `check_quay_staleness.sh`,
   `check_quay_pull_source.sh`.
5. **Credential liveness** — Google OAuth grants tested by asking the backend
   container to exercise its own refresh token, so the agent never reads a
   credential. `check_google_oauth.sh`.
6. **Edge and local services** — Cloudflare zone analytics, systemd unit drift,
   local TCP reachability. `check_cloudflare_status.sh`,
   `check_systemd_units.sh`, `check_tcp_local.sh`.
7. **Backup freshness** — the weekly pCloud dumps by age and size floor
   (`check_backup_freshness.sh`), and the nightly in-container dumps read on disk
   under `/var/srv` before they ever reach pCloud (`check_nightly_dump.sh` +
   `srv-nightly-dump-collect.sh`). The nightly check escalates to root via
   `podman_exec.sh`, the same split the drift checks use, because one service
   writes its dump `0600`.
7. **Configuration drift, three doors** — `/srv` against its own git
   (`check_git_drift.sh`), `/etc` against its `/srv` copy
   (`check_unit_drift.sh`), and a deployed config file against any OTHER git
   repo that also carries it (`check_config_drift.sh`). The third exists
   because the first two are single-repo by construction: a file with two git
   homes looks clean from inside either one, right up until someone syncs from
   the wrong one and production changes.

## Quick start

The image is not useful on its own — it needs a server to ask it questions.

```bash
podman run -d --name nagios-agent.crunchtools.com \
  --network=host --pid=host --privileged --memory=1g --memory-swap=1g \
  -v /srv/<service>/config/nrpe-host.cfg:/etc/nagios/nrpe.cfg:ro,Z \
  -v /srv/<service>/config/scripts:/usr/local/nagios/libexec:ro,Z \
  -v /run/podman/podman.sock:/run/podman/podman.sock \
  quay.io/crunchtools/nagios-agent:latest
```

Test any check the way Nagios does, which is the only test that counts:

```bash
check_nrpe -H 10.88.0.1 -p 5666 -c check_mem
```

## Configuration

Per constitution XIV, configuration is **not** baked into the image. The
deployed agent bind-mounts `/srv/<service>/config/` over
`/usr/local/nagios/libexec`, so **`/srv` is what actually runs** and the image's
own copy of a plugin is shadowed. Edit here, deploy there.

Per constitution XVII, no credential, mail address or account-scoped identifier
belongs in this repo — it is public. Plugins take an opaque key and resolve the
real value host-side:

```bash
check_cloudflare_status.sh <domain>       # -> /etc/nagios/cloudflare-zones.conf
check_google_oauth.sh      <account-key>  # -> /etc/nagios/google-accounts.conf
```

`deploy/nagios-agent/*.conf.example` shows the shape of each file. The real ones
live on the host and are committed to the private `/srv` repo.

| Path | What it is |
|------|------------|
| `deploy/nagios-agent/nrpe-host.cfg` | Command definitions for the `:5666` pool |
| `deploy/nagios-agent/nrpe-ctr.cfg` | Command definitions for the `:5667` pool |
| `deploy/nagios/*.cfg` | Nagios **server** service definitions that pair with these plugins |
| `deploy/systemd/*.service` | Both agent units as deployed |
| `*.conf.example` | Host lookup tables — shape only, never values |

## Writing a check

Constitution XVI governs these; the short version:

- **Standalone.** It must run via `check_nrpe` and give Nagios's answer. No
  dependency on an MCP server, an agent, or any orchestration layer — if the
  gateway is down, a check built on it goes blind exactly when it is needed.
- **Deterministic.** A stat call, a date comparison, a plain conditional. Never
  ask a model for the verdict. Non-determinism belongs in *remediation*.
- **Credential-free where it can be.** A file mtime or a Unix socket beats an
  API call with a token. To read another container's state, use the podman exec
  socket rather than bind-mounting its SELinux-labeled data.
- **Bounded.** You are running inside a memory cap and an NRPE
  `command_timeout`. Know your peak RSS and wall time. RT #1459 was a plugin
  sitting at 96% of the cap, and it OOM-killed the daemon seven times in a day.
- **Exercise every branch** through `check_nrpe` before calling it done — OK,
  WARNING, CRITICAL and the unknowns — not just the happy path.

## Development

```bash
podman build -t nagios-agent:test -f Containerfile .
RUNTIME=podman IMAGE=nagios-agent:test ./tests/test-image.sh
podman run --rm -v "$PWD":/src:rw,Z -w /src quay.io/crunchtools/gourmand:latest --full .
```

Plugins are tracked `100755` and the Containerfile chmods them with a glob. Do
not reintroduce an explicit file list — the previous one silently fell five
plugins behind and shipped them non-executable.

CI runs the build, `tests/test-image.sh`, Gourmand (blocking) and Gatehouse
(advisory) on every pull request.

## Documentation

| Page | Contents |
|------|----------|
| [`.specify/memory/constitution.md`](.specify/memory/constitution.md) | Per-repo constitution — profile, deployment topology, plugin rules |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history |
| [`crunchtools/constitution`](https://github.com/crunchtools/constitution) | Universal rules; XVI (monitoring) and XVII (secrets) apply most here |
| [`crunchtools/nagios`](https://github.com/crunchtools/nagios) | The server that queries this agent |

## License

AGPL-3.0-or-later.
