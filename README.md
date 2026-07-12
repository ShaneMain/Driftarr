<p align="center">
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0" />
  <img src="https://img.shields.io/badge/docker-compose-2496ED?logo=docker&logoColor=white" alt="Docker Compose" />
  <img src="https://img.shields.io/badge/CI%2FCD-GitHub_Actions-2088FF?logo=githubactions&logoColor=white" alt="GitHub Actions" />
  <img src="https://img.shields.io/badge/network-Tailscale-4C8BF5?logo=tailscale&logoColor=white" alt="Tailscale" />
  <img src="https://img.shields.io/badge/IaC-GitOps-F05032?logo=git&logoColor=white" alt="GitOps" />
  <img src="https://img.shields.io/badge/zero_trust-WireGuard-88171A?logo=wireguard&logoColor=white" alt="WireGuard" />
  <img src="https://img.shields.io/badge/python-3.12-3776AB?logo=python&logoColor=white" alt="Python 3.12" />
</p>

# Driftarr

A production-ready CI/CD framework for self-hosted Docker Compose infrastructure. Push to `main` and only the stacks that changed get redeployed — with automatic rollback, zero-trust networking, and GitOps-driven configuration management.

Service configs (custom formats, quality profiles, naming conventions) are version-controlled as JSON and bidirectionally synced — code pushes to APIs at deploy time, UI changes export back to git on a cron. The repo is the single source of truth: delete a config file and the corresponding resources get removed from the live service. No config data ships with the template — the first export bootstraps `configs/data/` from your live services as a baseline.

No more SSHing into servers to run `docker compose up -d` by hand.

---

## Overview

Driftarr applies DevOps and Infrastructure as Code (IaC) principles to self-hosted Docker Compose environments. It ships with a media server stack (Sonarr, Radarr, Bazarr, Prowlarr, NZBGet) and a VPN-tunneled download setup, plus a Homepage dashboard and AdGuard local DNS tying it together, as a working reference implementation, but the pipeline itself is stack-agnostic — any Docker Compose service works.

The deploy pipeline, security model, and config sync engine are the core value. The included stacks are just a starting point.

## When to use this (and when not to)

Driftarr targets a specific niche: a **single self-hosted server** running **Docker Compose**, where you want git-driven deploys **and** version-controlled application config (not just infrastructure). It is not a Kubernetes or multi-node tool.

| If you want… | Consider instead |
| --- | --- |
| Kubernetes GitOps | [Flux](https://fluxcd.io/) / [Argo CD](https://argoproj.github.io/argo-cd/) |
| Multi-host fleet configuration | [Ansible](https://www.ansible.com/) / [Nomad](https://www.nomadproject.io/) |
| A managed self-host PaaS | [Coolify](https://coolify.io/) / [Dokku](https://dokku.com/) / [CapRover](https://caprover.com/) |
| A web UI for ad-hoc container management | [Komodo](https://komo.do/) / [Portainer](https://www.portainer.io/) / [Dockge](https://github.com/louislam/dockge) |
| Only image auto-updates | [Watchtower](https://containrrr.dev/watchtower/) / [What's Up Docker](https://fmartinou.github.io/whats-up-docker/) |

**What Driftarr does that those don't:** treat *application config* (Radarr custom formats, qBittorrent preferences, quality/naming profiles) as declarative git state with **bidirectional** sync — the repo is the source of truth on deploys, and edits made in the UI flow back into git on a cron. It is purpose-built for the `*arr` / self-hosted-media homelab, and for owners who want the safety of GitOps (reviewable changes, automatic rollback, auditable history) without adopting Kubernetes.

## Key Features

- **Git-managed infrastructure + app config** — Docker Compose stacks, service settings (custom formats, quality profiles, naming conventions, media management), and deploy logic all live in version control, with an extensible configuration sync framework that captures changes from both code and UI
- **Push-to-deploy pipeline** — GitHub Actions detects changed files, maps them to stacks, and deploys only what changed
- **Automatic rollback** — failed health checks trigger per-stack rollback to the last known-good state
- **Zero-trust networking** — deploys flow through Tailscale's WireGuard mesh via ephemeral OAuth nodes; no ports exposed to the internet
- **Three-layer deploy security** — `authorized_keys` command restriction + sshd `ForceCommand` + sudoers scoping; the deploy user can only execute `deploy.sh`
- **GitOps config sync** — bidirectional: code changes push to service APIs at deploy time, UI changes export back to git on a cron
- **Plugin-based config engine** — auto-discovering Python modules; add a new app by dropping a single file in `modules/`
- **Interactive setup wizard** — `setup.sh` handles cloning, `.env` configuration, deploy user creation, SSH keys, GitHub secrets, workflow activation, and first deploy
- **Composable stack architecture** — hierarchical `common.yml` inheritance for DRY fleet-wide and per-stack defaults
- **Hot-reload support** — deploy.sh detects config-only changes and can reload services without full restarts
- **Structured deploy logging** — before/after container state snapshots, config diffs, and a deploy summary streamed to your terminal via GitHub Actions
- **CI validation** — compose file syntax, shell script syntax checking, Python compilation, and project structure checks on every push and PR

## Quick Start

### 1. Create your repo

Click **"Use this template"** on GitHub → **"Create a new repository"** → make it **private**.

Your Docker configs, API keys, and server paths don't belong in a public repo.

### 2. Install prerequisites

On your server: Docker, Docker Compose v2, Git, Python 3, [Tailscale](https://tailscale.com/).

### 3. Run the setup wizard

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ShaneMain/Driftarr/main/setup.sh)
```

The wizard handles: cloning, `.env` configuration, deploy user creation, SSH key generation, GitHub secrets guidance, workflow activation, config export cron, and initial deployment.

For manual setup, see [docs/server-setup.md](docs/server-setup.md). For common issues, see [docs/troubleshooting.md](docs/troubleshooting.md).

## Architecture

```
┌─────────────┐     push to main     ┌──────────────────┐
│  Developer   │ ──────────────────→  │  GitHub Actions   │
│  (local)     │                      │  (CI/CD runner)   │
└─────────────┘                      └────────┬─────────┘
                                              │
                                    Tailscale WireGuard mesh
                                     (ephemeral OAuth node)
                                              │
                                     ┌────────▼─────────┐
                                     │  deploy@server    │
                                     │  (locked-down)    │
                                     └────────┬─────────┘
                                              │
                                     sudo -u $USER deploy.sh
                                              │
                              ┌───────────────┼───────────────┐
                              │               │               │
                        ┌─────▼─────┐   ┌─────▼─────┐   ┌────▼──────┐
                        │   media   │   │ downloads │   │ monitoring│
                        │   stack   │   │   stack    │   │   stack   │
                        └───────────┘   └───────────┘   └───────────┘
```


### Project Structure

```
├── .github/workflows/
│   ├── deploy.yml              # CD pipeline — Tailscale → SSH → deploy.sh
│   └── validate.yml            # CI checks — compose, bash, Python, structure
├── setup.sh                    # Interactive setup/uninstall wizard
├── deploy.sh                   # Intelligent deploy script (runs on server)
├── common.yml                  # Fleet-wide defaults (restart policy, TZ, labels)
├── .env.example                # Template for secrets and host paths
├── docker-compose.yml          # Root compose — includes all stacks
├── configs/                    # GitOps config sync engine
│   ├── Dockerfile              # Python 3.12 Alpine container (stdlib only)
│   ├── run-export.sh           # Cron wrapper for config export
│   └── sync/                   # Plugin-based Python package
│       ├── base.py             # AppModule base class (API helpers, JSON I/O)
│       ├── sync.py             # Push: data/ JSON → service APIs
│       ├── export.py           # Pull: service APIs → data/ JSON + git commit
│       └── modules/            # Auto-discovered per-app plugins
│           ├── radarr.py       # Radarr: CFs, profiles, quality, naming, etc.
│           └── sonarr.py       # Sonarr: inherits Radarr, different endpoints
├── media/                      # Sonarr, Radarr, Bazarr, NZBGet, config-sync
│   ├── common.yml              # Media defaults (extends root + PUID/PGID)
│   └── docker-compose.yml
├── downloads/                   # Gluetun VPN + qBittorrent + Prowlarr
│   ├── common.yml
│   └── docker-compose.yml
├── dashboard/                  # Homepage landing page + read-only docker proxy
│   ├── docker-compose.yml
│   └── config/                 # services.yaml (app list), settings.yaml, ...
├── dns/                        # AdGuard Home — *.home local DNS + ad blocking
│   ├── docker-compose.yml
│   └── AdGuardHome.yaml        # First-boot seed (see dns/README.md)
├── monitoring/                 # Optional: Prometheus + Grafana + Node Exporter
│   ├── docker-compose.yml
│   └── prometheus.yml
└── docs/
    └── server-setup.md         # Manual setup reference
```

## How It Works

### Deploy Pipeline

`deploy.sh` is the core of the system. It runs on the server, triggered by GitHub Actions over SSH:

1. `git pull --ff-only` — fast-forward only, fails cleanly if the branch has diverged
2. Diffs `HEAD~1..HEAD` to identify changed files
3. Maps file paths to stacks — any directory containing a `docker-compose.yml` is auto-discovered
4. For each affected stack:
   - Snapshots running container states (before)
   - Runs `docker compose up -d` (with `build` for image-building stacks)
   - Snapshots container states (after)
   - Runs health checks — if unhealthy, rolls back that stack to the previous commit and redeploys
5. Runs config-sync as a dedicated post-deploy step (always, regardless of what changed) — rebuilds the image if sync code changed, then force-recreates the one-shot container
6. Prints a structured summary: deployed, config sync status, rolled back, failed

Special behaviors:
- `common.yml` changes trigger all stacks (fleet-wide defaults)
- `configs/sync/` or `configs/Dockerfile` changes trigger a config-sync image rebuild
- Auto-export commits (`chore(configs): auto-export`) are detected and skipped — the configs are already live
- If `git pull` is a no-op (commit pushed from the server itself), falls back to `HEAD~1..HEAD` so the deploy still runs

### Deploy Output

```
▶ Deploying abc1234 → def5678
  Commit: feat: update sonarr config
────────────────────────────────────────
▶ Changed files:
    media/docker-compose.yml
────────────────────────────────────────
▶ Stacks to deploy: media
────────────────────────────────────────
▶ Deploying: media
  Before:
    sonarr Up 3 days (healthy)
    radarr Up 3 days (healthy)
  After:
    sonarr Up 2 seconds (health: starting)
    radarr Up 3 days (healthy)
  ✅ media deployed successfully
────────────────────────────────────────
▶ Deploy Summary (abc1234 → def5678)
  ✅ Deployed: media
▶ Deploy complete.
```

### Composable Stack Defaults

Root `common.yml` defines fleet-wide defaults. Stack-level `common.yml` files extend it with stack-specific settings. Every service extends its stack's common:

```yaml
# common.yml (root) — fleet-wide
services:
  default:
    restart: unless-stopped
    environment:
      TZ: ${TZ:-America/New_York}

# media/common.yml — extends root, adds media defaults
services:
  default:
    extends:
      file: ../common.yml
      service: default
    environment:
      PUID: "1000"
      PGID: "1000"

# media/docker-compose.yml — each service extends stack common
services:
  sonarr:
    extends:
      file: ./common.yml
      service: default
    image: ghcr.io/linuxserver/sonarr:latest
```

Change root `common.yml` → all stacks redeploy. Change `media/common.yml` → only the media stack redeploys.

### GitOps Config Sync

The `configs/` directory implements a bidirectional GitOps loop for service configuration:

```
┌──────────────┐   sync (deploy)   ┌──────────────┐
│  configs/    │ ────────────────→  │  Service     │
│  data/*.json │                    │  APIs        │
│              │ ←────────────────  │              │
└──────────────┘   export (cron)   └──────────────┘
        │                                  │
        └──── git commit/push ─────────────┘
```

The repo is the single source of truth. `configs/data/` ships empty — the first export run bootstraps it by pulling your live service configs as a baseline. From that point on:

- **Sync** (push): runs as a one-shot container on every deploy (diff-agnostic, idempotent), reads JSON from `configs/data/` and pushes to service APIs. If a file is missing, all corresponding resources are deleted from the API.
- **Export** (pull): runs on a host cron, pulls current config from APIs, diffs against git, and commits/pushes changes

Fully declarative: the JSON files define the desired state. Resources in the API that aren't in the JSON get deleted. Singleton configs (naming, media management) skip when the file is absent.

Loop prevention:
1. Sync writes a marker file — export skips if the marker is less than 5 minutes old
2. `deploy.sh` detects auto-export commits and skips the deploy (configs are already live)

What gets synced: custom formats, quality profile scores, quality definitions, naming formats, media management settings, root folders, and download client post-import categories.

### Plugin Architecture

Each app is a Python module in `configs/sync/modules/`. The engine auto-discovers them at runtime — drop a new `.py` file and it gets picked up. Each module subclasses `AppModule` and implements `sync()` and `export()`:

```python
# configs/sync/modules/myapp.py
from configs.sync.base import AppModule

class MyAppModule(AppModule):
    name = "myapp"
    url_env = "MYAPP_URL"
    key_env = "MYAPP_API_KEY"
    default_url = "http://myapp:8080"

    def sync(self):
        # Read self.load_json("settings.json"), push to API
        ...

    def export(self):
        # Pull from API, write with self.write_json("settings.json", data)
        ...
```

No registration, no config files — just the module file. The base class provides API helpers (`api_get`, `api_put`, `api_post`, `api_delete`), JSON I/O, health checks, and logging.

### Security Model

The deploy pipeline uses a zero-trust architecture with defense in depth:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| Network | Tailscale WireGuard mesh | No open ports; SSH only reachable via Tailscale |
| Authentication | Ephemeral OAuth node (`tag:ci`) | Runner joins mesh for the job, auto-removed after |
| Authorization | `authorized_keys` `command=` | Forces deploy user to run `deploy.sh` only |
| Authorization | sshd `ForceCommand` | Second independent layer — same restriction |
| Privilege | sudoers scoping | `deploy` can only `sudo -u $USER deploy.sh` |
| Secrets | GitHub Actions secrets | SSH key, Tailscale OAuth credentials never in code |
| Secrets | gitleaks CI gate | Scans every push/PR for leaked credential patterns |
| Secrets | secret-guard hooks (`core.hooksPath .githooks`) | Blocks any commit/push containing a literal `.env` value before it leaves the machine |

The `deploy` user has no password, no shell access, and no permissions beyond executing the deploy script as the owning user.

### Preventing secret leaks

Two independent layers catch leaked secrets at different points:

- **`secret-guard` (pre-commit / pre-push hooks)** — proactive. Reads the real values from your `.env` and blocks any commit or push whose tracked files contain a literal match. This is exact-value matching, so it catches *this* deployment's actual keys, not just generic patterns. Installed by `setup.sh` via `git config core.hooksPath .githooks`; a no-op on machines without a `.env` (CI, fresh clones). To auto-fix a hit in a shell/compose file, run `scripts/secret-guard.sh --fix` (replaces the literal with `${VAR}`, which bash/compose expand at runtime).
- **gitleaks (CI gate)** — reactive backstop. Pattern-based scan of every push/PR in case a secret slips past the hooks (e.g., committed on a machine without the hook installed).

## Extending

### Adding a new stack

1. Create a directory with a `docker-compose.yml`
2. Extend from `common.yml` (or create a stack-level `common.yml` for shared defaults)
3. Optionally add it to the root `docker-compose.yml` includes
4. Push — `deploy.sh` auto-discovers it from the changed file paths

```yaml
# my-stack/docker-compose.yml
services:
  my-service:
    extends:
      file: ../common.yml
      service: default
    image: my-image:latest
    ports:
      - "8080:8080"
    volumes:
      - ${DOCKER_DIR}/my-service:/config
```

### Adding a media server

```yaml
# media-server/docker-compose.yml (or add to media/docker-compose.yml)
services:
  plex:  # or jellyfin, emby, etc.
    extends:
      file: ../common.yml
      service: default
    image: ghcr.io/linuxserver/plex:latest
    ports:
      - "32400:32400"
    volumes:
      - ${DOCKER_DIR}/plex:/config
      - ${MEDIA_DIR}:/media
```

### Stacks that build images

If a stack uses a `Dockerfile` instead of pulling from a registry, set `DEPLOY_BUILD_STACKS` in `deploy.sh`:

```bash
DEPLOY_BUILD_STACKS="notifications my-custom-stack"
```

These stacks get `docker compose build` before `docker compose up -d`.

### Adding a config sync module

Drop a Python file in `configs/sync/modules/` — it's auto-discovered. See the [plugin architecture](#plugin-architecture) section above.

### Setting up the export cron

```bash
# Add to crontab — runs every hour, captures UI changes back into git
0 * * * * /path/to/docker-stacks/configs/run-export.sh >> $HOME/config-export.log 2>&1
```

The first run bootstraps `configs/data/` by pulling live configs from your services — this becomes your baseline. No sample configs ship with the template because every setup is different. From there, any changes you make in the UI get captured back into git automatically.

Preview before applying:

```bash
# Dry-run export (writes to /tmp, shows diff)
./configs/run-export.sh --dry-run

# Dry-run sync (shows what would change)
docker compose -f media/docker-compose.yml run --rm config-sync diff
```

## Configuration

Environment variables in `deploy.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `DEPLOY_REPO_DIR` | `/home/$USER/docker-stacks` | Path to the repo on the server |
| `DEPLOY_LOG_TAG` | `driftarr` | Syslog tag for deploy logs |
| `DEPLOY_BRANCH` | `main` | Branch to deploy from |
| `DEPLOY_BUILD_STACKS` | _(empty)_ | Space-separated stacks that need `docker compose build` |

## Requirements

| Dependency | Purpose |
|------------|---------|
| Docker + Compose v2 | Container runtime |
| Git | Version control + deploy mechanism |
| Python 3 | Config sync engine (stdlib only, no pip packages) |
| [Tailscale](https://tailscale.com/) | Zero-trust networking for deploys |
| [GitHub CLI](https://cli.github.com/) | Optional — for local `driftarr` command |

## License

[GPL-3.0](LICENSE)

## Author

[Shane Main](https://github.com/ShaneMain)
