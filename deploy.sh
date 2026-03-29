#!/usr/bin/env bash
set -euo pipefail

# ── Driftarr Deploy Entrypoint ────────────────────────
# Thin wrapper that sources deploy/lib.sh then runs each module in order.
# After git pull, modules are read fresh from disk — so changes to deploy/*
# take effect immediately without a re-exec. Only changes to this file
# (deploy.sh itself) trigger a re-exec.

# Ensure unbuffered output so SSH streams logs in real-time
export PYTHONUNBUFFERED=1
exec 2>&1

# Ignore SIGPIPE — prevents exit code 141 when SSH pipe closes during large output
trap '' PIPE

# ── Configuration ─────────────────────────────────────
REPO_DIR="${DEPLOY_REPO_DIR:-/home/$USER/docker-stacks}"
LOG_TAG="${DEPLOY_LOG_TAG:-driftarr}"
BRANCH="${DEPLOY_BRANCH:-main}"
BUILD_STACKS="${DEPLOY_BUILD_STACKS:-}"
CONFIG_SYNC_STACK="${DEPLOY_CONFIG_SYNC_STACK:-media}"

cd "$REPO_DIR"

# ── Source shared library ─────────────────────────────
source "$REPO_DIR/deploy/lib.sh"

# ── Run modules in order ──────────────────────────────
# Each file in deploy/ matching [0-9]*.sh is sourced in lexical order.
# Modules share state via variables defined in lib.sh.
for module in "$REPO_DIR"/deploy/[0-9]*.sh; do
  [ -f "$module" ] || continue
  source "$module"
done
