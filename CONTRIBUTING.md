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

## Preventing secret leaks

`setup.sh` enables `git config core.hooksPath .githooks`, which activates `pre-commit` and `pre-push` hooks backed by `scripts/secret-guard.sh`. The hook reads the real values from your `.env` and **blocks** any commit/push whose tracked files contain a literal match — so a key that lives in `.env` can't be committed even by accident. It is a no-op on machines without a `.env` (CI, fresh clones); the gitleaks CI gate is the pattern-based backstop.

- A value is guarded when its env-var name matches `key|secret|token|pass(word|wd)?|private|credential` (case-insensitive) and is ≥ 12 chars. Paths, `TZ`, `PUID`, etc. are left alone.
- Hits in `configs/data/**` (auto-export), `.env*`, and `*.enc.*` (SOPS ciphertext) are not scanned — they're trusted/encrypted.
- To auto-fix a hit in a shell/compose file, run `scripts/secret-guard.sh --fix` — it rewrites the literal to `${VAR}`, which bash and docker compose expand at runtime. JSON / Python files can't be auto-fixed (no runtime `${VAR}` expansion); the hook message shows the manual substitution.
- Tune detection with `SECRET_GUARD_KEY_RE`, `SECRET_GUARD_MIN_LEN`, or `SECRET_GUARD_ENV` (e.g. to point at a non-default env file).
