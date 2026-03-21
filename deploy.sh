#!/usr/bin/env bash
set -euo pipefail

# Ensure unbuffered output so SSH streams logs in real-time
export PYTHONUNBUFFERED=1
exec 2>&1

# Ignore SIGPIPE — prevents exit code 141 when SSH pipe closes during large output
trap '' PIPE

# ── Configuration ─────────────────────────────────────
REPO_DIR="${DEPLOY_REPO_DIR:-/home/$USER/docker-stacks}"
LOG_TAG="${DEPLOY_LOG_TAG:-driftarr}"
BRANCH="${DEPLOY_BRANCH:-main}"

# Stacks that require `docker compose build` before `up -d`
BUILD_STACKS="${DEPLOY_BUILD_STACKS:-}"

# Track results for summary
SUCCEEDED=""
FAILED=""
ROLLED_BACK=""
SCRIPT_CHANGES=""

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

# If the pull was a no-op (e.g. commit pushed from this server), fall back to
# diffing HEAD~1..HEAD so the deploy still runs for the latest commit.
if [ "$BEFORE" = "$AFTER" ]; then
  BEFORE=$(git rev-parse HEAD~1)
  info "Already up to date — using HEAD~1..HEAD (${BEFORE:0:7}..${AFTER:0:7})"
fi

info "Deploying ${BEFORE:0:7} → ${AFTER:0:7}"
log "Commit: $(git log --oneline -1 "$AFTER")"

# Skip deploy for auto-export commits (configs are already live on services)
COMMIT_MSG=$(git log --format=%s -1 "$AFTER")
if echo "$COMMIT_MSG" | grep -q '^chore(configs): auto-export'; then
  info "Auto-export commit detected — configs already live, skipping deploy."
  exit 0
fi
sep

# ── Detect Changes ────────────────────────────────────
CHANGED=$(git diff --name-only "$BEFORE" "$AFTER")

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

# ── Log Changed Files ─────────────────────────────────
info "Changed files:"
for file in $CHANGED; do
  log "  $file"
done
sep

for file in $CHANGED; do
  case "$file" in
    */*.sh) SCRIPT_CHANGES="$SCRIPT_CHANGES ${file##*/}" ;;
  esac
done

if [ -n "$STACKS" ]; then
  info "Stacks to deploy: $STACKS"
fi
sep

# ── Helper: capture container states for a stack ──────
snapshot_containers() {
  local stack_dir="$1"
  if [ "$stack_dir" = "root" ]; then
    docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null || true
  else
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack_dir/docker-compose.yml" ps --format '{{.Name}} {{.Status}}' 2>/dev/null || true
  fi
}

# ── Helper: check if stack needs build step ───────────
needs_build() {
  local stack="$1"
  echo "$BUILD_STACKS" | tr ' ' '\n' | grep -qx "$stack"
}

# ── Helper: deploy a single stack ─────────────────────
deploy_stack() {
  local stack="$1"
  info "Deploying: $stack"

  local before_state
  before_state=$(snapshot_containers "$stack")
  if [ -n "$before_state" ]; then
    log "Before:"
    echo "$before_state" | while read -r line; do log "  $line"; done
  fi

  if [ "$stack" = "root" ]; then
    log "Root compose changed — recreating all"
    docker compose up -d 2>&1 | while read -r line; do log "$line"; done
  elif needs_build "$stack"; then
    log "Building $stack images..."
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" build 2>&1 | tail -5 | while read -r line; do log "$line"; done
    log "Starting $stack..."
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | while read -r line; do log "$line"; done
  else
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | while read -r line; do log "$line"; done
  fi

  sleep 2
  local after_state
  after_state=$(snapshot_containers "$stack")
  if [ -n "$after_state" ]; then
    log "After:"
    echo "$after_state" | while read -r line; do log "  $line"; done
  fi

  # Quick health check
  local unhealthy
  unhealthy=$(echo "$after_state" | grep -ivE '(running|healthy|Up)' || true)
  if [ -n "$unhealthy" ]; then
    warn "Unhealthy containers detected in $stack:"
    echo "$unhealthy" | while read -r line; do warn "  $line"; done
    return 1
  fi

  ok "$stack deployed successfully"
  return 0
}

# ── Helper: rollback a single stack ───────────────────
rollback_stack() {
  local stack="$1"
  warn "Rolling back $stack to ${BEFORE:0:7}..."

  git checkout "$BEFORE" -- "$stack/" 2>/dev/null || git checkout "$BEFORE" -- "$stack" 2>/dev/null || true

  if [ "$stack" = "root" ]; then
    git checkout "$BEFORE" -- docker-compose.yml 2>/dev/null || true
    docker compose up -d 2>&1 | while read -r line; do log "$line"; done
  elif needs_build "$stack"; then
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" build 2>&1 | tail -3 | while read -r line; do log "$line"; done
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | while read -r line; do log "$line"; done
  else
    docker compose -p "$(basename "$REPO_DIR")" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | while read -r line; do log "$line"; done
  fi

  git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true

  ROLLED_BACK="$ROLLED_BACK $stack"
  warn "$stack rolled back to ${BEFORE:0:7}"
}

# ── Deploy Each Stack ─────────────────────────────────
set +e
for stack in $STACKS; do
  if deploy_stack "$stack"; then
    SUCCEEDED="$SUCCEEDED $stack"
  else
    FAILED="$FAILED $stack"
    err "$stack deploy failed — initiating rollback"
    rollback_stack "$stack"
  fi
  sep
done
set -e

# ── Summary ───────────────────────────────────────────
sep
info "Deploy Summary (${BEFORE:0:7} → ${AFTER:0:7})"

if [ -n "$SUCCEEDED" ]; then
  ok "Deployed:$SUCCEEDED"
fi
if [ -n "$SCRIPT_CHANGES" ]; then
  log "📝 Scripts updated (no restart needed):$SCRIPT_CHANGES"
fi
if [ -n "$ROLLED_BACK" ]; then
  warn "Rolled back:$ROLLED_BACK"
fi
if [ -n "$FAILED" ]; then
  err "Failed:$FAILED"
  exit 1
fi

info "Deploy complete."
