# Contributing to Driftarr

Thanks for your interest in contributing. Here's how to get involved.

## Reporting Issues

Open an issue using one of the templates. Include:
- What you expected vs what happened
- Relevant logs (deploy output, `docker compose logs`, etc.)
- Your OS and Docker/Compose versions

## Pull Requests

1. Fork the repo and create a branch from `main`
2. Make your changes — keep commits focused and use [conventional commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, etc.)
3. Run the CI checks locally before pushing:
   ```bash
   # Compose syntax
   docker compose -f docker-compose.yml config --quiet

   # Shell syntax
   bash -n deploy.sh setup.sh configs/run-export.sh

   # Python compilation
   python3 -m py_compile configs/sync/base.py
   python3 -m py_compile configs/sync/sync.py
   python3 -m py_compile configs/sync/export.py
   ```
4. Open a PR against `main` with a clear description of what changed and why

## Adding a Config Sync Module

Drop a new file in `configs/sync/modules/`. See the [plugin architecture](README.md#plugin-architecture) section in the README and use `radarr.py` as a reference. The engine auto-discovers modules — no registration needed.

## Code Style

- Shell: 2-space indent, `set -euo pipefail`
- Python: 4-space indent, stdlib only (no pip dependencies)
- YAML: 2-space indent
- See `.editorconfig` for the full spec

## Scope

The deploy pipeline, security model, and config sync engine are the core of the project. The included stacks (media, downloads, monitoring) are a reference implementation — PRs that improve the framework are prioritized over stack-specific changes.
