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
REPO_DIR="${DEPLOY_REPO_DIR:-/home/${USER:-$(id -un)}/docker-stacks}"
LOG_TAG="${DEPLOY_LOG_TAG:-driftarr}"
BRANCH="${DEPLOY_BRANCH:-main}"
BUILD_STACKS="${DEPLOY_BUILD_STACKS:-}"
CONFIG_SYNC_STACK="${DEPLOY_CONFIG_SYNC_STACK:-media}"

cd "$REPO_DIR"

# ── Single-deploy lock ────────────────────────────────
# Stop two deploys from interleaving git pull, autostash, and the rollback
# checkout window. GitHub's concurrency group only serializes Actions runs, not
# an Actions run racing a manual server-side deploy. flock releases the fd
# automatically on any exit (including SIGKILL), so there is no stale lock.
# Wait (bounded) rather than fail fast: a CI deploy that arrives during a
# manual run must be queued, not dropped — otherwise its commit is never
# deployed until the next push. configs/run-export.sh takes the same lock
# (non-blocking) so the export cron can't commit mid-rollback; the default
# path is duplicated in deploy/lib.sh (DEPLOY_LOCK_FILE) — keep them in sync.
DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-$REPO_DIR/.deploy.lock}"
DEPLOY_LOCK_TIMEOUT="${DEPLOY_LOCK_TIMEOUT:-1500}"
exec 9>"$DEPLOY_LOCK_FILE"
if ! flock -w "$DEPLOY_LOCK_TIMEOUT" 9; then
  echo "⚠️  Another deploy held $DEPLOY_LOCK_FILE for ${DEPLOY_LOCK_TIMEOUT}s — giving up." >&2
  exit 1
fi

# ── Failure notification (optional) ───────────────────
# Set DEPLOY_NOTIFY_URL to a webhook that accepts {"title","message"} JSON
# (ntfy, Gotify, a Signal relay, ...) to get alerted when a deploy fails.
# Any module failure (set -e or explicit exit >0) lands here before dying.
notify_failure() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ -z "${DEPLOY_NOTIFY_URL:-}" ] && return 0
  local commit
  commit=$(git log --oneline -1 2>/dev/null | head -c 120 | tr '"\\' "'/")
  curl -sf -m 10 -X POST "$DEPLOY_NOTIFY_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"title\": \"❌ Deploy failed (exit $rc)\", \"message\": \"$commit — check: journalctl -t $LOG_TAG -n 100\"}" \
    >/dev/null 2>&1 || true
}
trap notify_failure EXIT

# ── Source shared library ─────────────────────────────
source "$REPO_DIR/deploy/lib.sh"

# ── Run modules in order ──────────────────────────────
# Each file in deploy/ matching [0-9]*.sh is sourced in lexical order.
# Modules share state via variables defined in lib.sh.
for module in "$REPO_DIR"/deploy/[0-9]*.sh; do
  [ -f "$module" ] || continue
  source "$module"
done
