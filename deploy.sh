#!/usr/bin/env bash
set -euo pipefail

# Ensure unbuffered output so SSH streams logs in real-time
export PYTHONUNBUFFERED=1
exec 2>&1

# ── Configuration ─────────────────────────────────────
REPO_DIR="${DEPLOY_REPO_DIR:-/home/$USER/docker-stacks}"
LOG_TAG="${DEPLOY_LOG_TAG:-driftarr}"
BRANCH="${DEPLOY_BRANCH:-main}"

# Track results for summary
SUCCEEDED=""
FAILED=""

log()  { logger -t "$LOG_TAG" -- "$*"; echo "  $*"; }
info() { logger -t "$LOG_TAG" -- "$*"; echo "▶ $*"; }
ok()   { logger -t "$LOG_TAG" -- "OK: $*"; echo "  ✅ $*"; }
err()  { logger -t "$LOG_TAG" -- "FAIL: $*"; echo "  ❌ $*"; }
warn() { logger -t "$LOG_TAG" -- "WARN: $*"; echo "  ⚠️  $*"; }
sep()  { echo "────────────────────────────────────────"; }

cd "$REPO_DIR"

# ── Git Pull ──────────────────────────────────────────
BEFORE=$(git rev-parse HEAD)
info "Pulling latest changes..."
git pull --ff-only origin "$BRANCH"
AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" = "$AFTER" ]; then
  info "Already up to date — nothing to deploy."
  exit 0
fi

info "Deploying ${BEFORE:0:7} → ${AFTER:0:7}"
log "Commit: $(git log --oneline -1 "$AFTER")"
sep

# ── Detect Changes ────────────────────────────────────
CHANGED=$(git diff --name-only "$BEFORE" "$AFTER")

# Auto-discover stacks from changed file paths
STACKS=""
for file in $CHANGED; do
  dir=$(echo "$file" | cut -d/ -f1)
  if [ -f "$REPO_DIR/$dir/docker-compose.yml" ] 2>/dev/null; then
    STACKS="$STACKS $dir"
  fi
  if [ "$file" = "common.yml" ]; then
    for d in "$REPO_DIR"/*/; do
      [ -f "$d/docker-compose.yml" ] && STACKS="$STACKS $(basename "$d")"
    done
  fi
  if [ "$file" = "docker-compose.yml" ]; then
    STACKS="$STACKS root"
  fi
done

STACKS=$(echo "$STACKS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

info "Changed files:"
for file in $CHANGED; do
  log "  $file"
done
sep

if [ -n "$STACKS" ]; then
  info "Stacks to deploy: $STACKS"
fi
sep

# ── Deploy Each Stack ─────────────────────────────────
for stack in $STACKS; do
  info "Deploying: $stack"
  if [ "$stack" = "root" ]; then
    docker compose up -d 2>&1 | while read -r line; do log "$line"; done
  else
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | while read -r line; do log "$line"; done
  fi
  ok "$stack deployed"
  SUCCEEDED="$SUCCEEDED $stack"
  sep
done

# ── Summary ───────────────────────────────────────────
sep
info "Deploy Summary (${BEFORE:0:7} → ${AFTER:0:7})"
if [ -n "$SUCCEEDED" ]; then
  ok "Deployed:$SUCCEEDED"
fi
info "Deploy complete."
