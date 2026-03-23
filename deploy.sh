#!/usr/bin/env bash
set -euo pipefail

# Ensure unbuffered output so SSH streams logs in real-time
export PYTHONUNBUFFERED=1
exec 2>&1

# Ignore SIGPIPE — prevents exit code 141 when SSH pipe closes during large output
trap '' PIPE

# ── Configuration ─────────────────────────────────────
# Override these via environment or edit directly
REPO_DIR="${DEPLOY_REPO_DIR:-/home/$USER/docker-stacks}"
LOG_TAG="${DEPLOY_LOG_TAG:-driftarr}"
BRANCH="${DEPLOY_BRANCH:-main}"

# Stacks that require `docker compose build` before `up -d`
# Space-separated list of stack names (directory names)
BUILD_STACKS="${DEPLOY_BUILD_STACKS:-}"

# Stack that contains the config-sync service (leave empty to disable config-sync)
CONFIG_SYNC_STACK="${DEPLOY_CONFIG_SYNC_STACK:-media}"

# Track results for summary
SUCCEEDED=""
FAILED=""
ROLLED_BACK=""
CONFIG_RELOADS=""
SCRIPT_CHANGES=""

log()  { logger -t "$LOG_TAG" -- "$*"; echo "  $*"; }
info() { logger -t "$LOG_TAG" -- "$*"; echo "▶ $*"; }
ok()   { logger -t "$LOG_TAG" -- "OK: $*"; echo "  ✅ $*"; }
err()  { logger -t "$LOG_TAG" -- "FAIL: $*"; echo "  ❌ $*"; }
warn() { logger -t "$LOG_TAG" -- "WARN: $*"; echo "  ⚠️  $*"; }
sep()  { echo "────────────────────────────────────────"; }

cd "$REPO_DIR"

# ── Re-exec guard ────────────────────────────────────
# If deploy.sh was updated by git pull, bash is still running the old copy
# from memory. We re-exec the on-disk version so changes take effect immediately.
# DEPLOY_REEXEC is set to pass the before/after refs so the re-exec'd script
# skips the pull and picks up where we left off.
if [ -n "${DEPLOY_REEXEC:-}" ]; then
  BEFORE="${DEPLOY_REEXEC_BEFORE}"
  AFTER="${DEPLOY_REEXEC_AFTER}"
  info "Re-exec'd with updated deploy.sh (${BEFORE:0:7} → ${AFTER:0:7})"
else
  # ── Git Pull ──────────────────────────────────────────
  BEFORE=$(git rev-parse HEAD)
  info "Pulling latest changes..."
  git pull --ff-only origin "$BRANCH"
  AFTER=$(git rev-parse HEAD)

  # If the pull was a no-op (e.g. commit pushed from this server), fall back to
  # diffing HEAD~1..HEAD so the deploy still runs for the latest commit.
  if [ "$BEFORE" = "$AFTER" ]; then
    if ! git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      info "Already up to date and only one commit exists — nothing to deploy."
      exit 0
    fi
    BEFORE=$(git rev-parse HEAD~1)
    info "Already up to date — using HEAD~1..HEAD (${BEFORE:0:7}..${AFTER:0:7})"
  fi

  # If deploy.sh changed, re-exec the updated version
  if git diff --name-only "$BEFORE" "$AFTER" | grep -qx 'deploy.sh'; then
    info "deploy.sh updated — re-executing with new version..."
    export DEPLOY_REEXEC=1 DEPLOY_REEXEC_BEFORE="$BEFORE" DEPLOY_REEXEC_AFTER="$AFTER"
    exec "$REPO_DIR/deploy.sh"
  fi
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

# Auto-discover stacks from changed file paths
# Any top-level directory containing a docker-compose.yml is a stack
STACKS=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(echo "$file" | cut -d/ -f1)
  if [ -f "$REPO_DIR/$dir/docker-compose.yml" ] 2>/dev/null; then
    STACKS="$STACKS $dir"
  fi
  # configs/ changes are handled by the always-run config-sync step below
  # Root-level common.yml affects all stacks
  if [ "$file" = "common.yml" ]; then
    for d in "$REPO_DIR"/*/; do
      [ -f "$d/docker-compose.yml" ] && STACKS="$STACKS $(basename "$d")"
    done
  fi
  # Root docker-compose.yml
  if [ "$file" = "docker-compose.yml" ]; then
    STACKS="$STACKS root"
  fi
done <<< "$CHANGED"

# Deduplicate
STACKS=$(echo "$STACKS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

# ── Helper: compute file checksum for a stack dir ─────
# Includes the root common.yml since all stacks extend it
stack_file_hash() {
  local stack_dir="$1"
  {
    find "$stack_dir" -maxdepth 1 -type f ! -name 'docker-compose.yml' -exec md5sum {} +
    [ -f "$REPO_DIR/common.yml" ] && md5sum "$REPO_DIR/common.yml"
  } 2>/dev/null | sort | md5sum | awk '{print $1}'
}

# ── Drift Detection ──────────────────────────────────
# Compare file checksums in each stack directory against the last successful
# deploy. This catches bind-mount drift (git replaces files atomically with
# new inodes) even when the compose definition hasn't changed.
DEPLOY_HASHES_DIR="$REPO_DIR/.deploy-hashes"
mkdir -p "$DEPLOY_HASHES_DIR"
DRIFT_STACKS=""
for d in "$REPO_DIR"/*/; do
  [ -f "$d/docker-compose.yml" ] || continue
  stack=$(basename "$d")
  repo_hash=$(stack_file_hash "$d")
  stored_hash=$(cat "$DEPLOY_HASHES_DIR/$stack" 2>/dev/null || echo "")
  if [ "$repo_hash" != "$stored_hash" ]; then
    # Only log drift for stacks not already in the deploy list
    if ! echo " $STACKS " | grep -q " $stack "; then
      log "Drift detected in $stack (file checksums changed since last deploy)"
      DRIFT_STACKS="$DRIFT_STACKS $stack"
    fi
  fi
done
STACKS="$STACKS $DRIFT_STACKS"
STACKS=$(echo "$STACKS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

# ── Log Changed Files ─────────────────────────────────
info "Changed files:"
while IFS= read -r file; do
  [ -z "$file" ] && continue
  log "  $file"
done <<< "$CHANGED"
sep

# Detect config changes that support hot-reload
PROMETHEUS_RELOAD=false
ALERTMANAGER_RELOAD=false
CONFIG_CHANGES=false
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    monitoring/prometheus.yml|monitoring/alert-rules.yml) PROMETHEUS_RELOAD=true ;;
    monitoring/alertmanager.yml) ALERTMANAGER_RELOAD=true ;;
    configs/*) CONFIG_CHANGES=true ;;
    */*.sh) SCRIPT_CHANGES="$SCRIPT_CHANGES ${file##*/}" ;;
  esac
done <<< "$CHANGED"

# ── Log Config Diffs ──────────────────────────────────
if [ "$CONFIG_CHANGES" = true ]; then
  info "Config file changes:"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      configs/data/*/*.json)
        log "  📋 $file"
        git diff "$BEFORE" "$AFTER" -- "$file" | grep '^[+-]' | grep -v '^[+-][+-][+-]' | head -30 | while read -r line; do
          log "    $line"
        done || true
        ;;
      configs/sync/*.py|configs/sync/modules/*.py)
        log "  📝 $file (sync engine updated)"
        ;;
      configs/Dockerfile)
        log "  🐳 $file (container build changed)"
        ;;
    esac
  done <<< "$CHANGED"
  sep
fi

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
    docker compose -p "$stack_dir" -f "$REPO_DIR/$stack_dir/docker-compose.yml" ps --format '{{.Name}} {{.Status}}' 2>/dev/null || true
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

  # Snapshot before
  local before_state
  before_state=$(snapshot_containers "$stack")
  if [ -n "$before_state" ]; then
    log "Before:"
    echo "$before_state" | while read -r line; do log "  $line"; done
  fi

  if [ "$stack" = "root" ]; then
    log "Root compose changed — recreating all"
    docker compose up -d --force-recreate 2>&1 | while read -r line; do log "$line"; done
  elif needs_build "$stack"; then
    log "Building $stack images..."
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" build 2>&1 | tail -5 | while read -r line; do log "$line"; done
    log "Starting $stack..."
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d --force-recreate 2>&1 | while read -r line; do log "$line"; done
  else
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d --force-recreate 2>&1 | while read -r line; do log "$line"; done
  fi

  # Wait for containers to settle past "health: starting" state
  # Most healthchecks have start_period=30s + interval=60s, so 90s covers the first check
  log "Waiting for health checks to settle..."
  local health_wait=0
  while [ $health_wait -lt 90 ]; do
    sleep 10
    health_wait=$((health_wait + 10))
    local current_state
    current_state=$(snapshot_containers "$stack")
    # If no containers are in "starting" state, we're done waiting
    if ! echo "$current_state" | grep -qi 'starting'; then
      break
    fi
    [ $((health_wait % 30)) -eq 0 ] && log "Still waiting for health checks... (${health_wait}s)"
  done

  # Wait for one-shot containers to finish (config-sync etc.)
  local oneshot_running=true wait_count=0
  while [ "$oneshot_running" = true ] && [ $wait_count -lt 120 ]; do
    local exited_check
    if [ "$stack" = "root" ]; then
      exited_check=$(docker compose ps --status=running --format '{{.Name}}' 2>/dev/null | grep -c 'sync\|oneshot\|migrate' || true)
    else
      exited_check=$(docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" ps --status=running --format '{{.Name}}' 2>/dev/null | grep -c 'sync\|oneshot\|migrate' || true)
    fi
    if [ "$exited_check" -gt 0 ]; then
      [ $wait_count -eq 0 ] && log "Waiting for one-shot containers to finish..."
      sleep 5
      wait_count=$((wait_count + 5))
    else
      oneshot_running=false
    fi
  done

  # Snapshot after one-shots have finished so their clean exits don't skew the health check
  local after_state
  after_state=$(snapshot_containers "$stack")
  if [ -n "$after_state" ]; then
    log "After:"
    echo "$after_state" | while read -r line; do log "  $line"; done
  fi

  # Health check — look for actually unhealthy containers (not just "starting")
  local unhealthy
  unhealthy=$(echo "$after_state" | grep -i 'unhealthy' || true)
  if [ -n "$unhealthy" ]; then
    warn "Unhealthy containers detected in $stack:"
    echo "$unhealthy" | while read -r line; do warn "  $line"; done
    return 1
  fi

  # Catch containers that exited unexpectedly (Exited (0) = successful one-shot, not a failure)
  local exited
  exited=$(echo "$after_state" | grep -ivE '(running|healthy|Up|starting|Exited \(0\))' || true)
  if [ -n "$exited" ]; then
    warn "Non-running containers detected in $stack:"
    echo "$exited" | while read -r line; do warn "  $line"; done
    return 1
  fi

  # Check for failed one-shot containers (restart: "no" that exited non-zero)
  local failed_oneshots
  if [ "$stack" = "root" ]; then
    failed_oneshots=$(docker compose ps -a --format '{{.Name}} {{.ExitCode}}' 2>/dev/null | awk '$2 != 0 && $2 != ""' || true)
  else
    failed_oneshots=$(docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" ps -a --format '{{.Name}} {{.ExitCode}}' 2>/dev/null | awk '$2 != 0 && $2 != ""' || true)
  fi
  if [ -n "$failed_oneshots" ]; then
    warn "Failed one-shot containers in $stack:"
    echo "$failed_oneshots" | while read -r line; do warn "  $line (exit code: $(echo "$line" | awk '{print $2}'))"; done
    return 1
  fi

  ok "$stack deployed successfully"

  # Store file checksum so future deploys can detect drift
  stack_file_hash "$REPO_DIR/$stack" > "$DEPLOY_HASHES_DIR/$stack"

  return 0
}

# ── Helper: rollback a single stack ───────────────────
rollback_stack() {
  local stack="$1"
  warn "Rolling back $stack to ${BEFORE:0:7}..."

  # If the script is killed between the two checkouts, restore HEAD so the
  # working tree doesn't end up stranded at $BEFORE.
  trap 'git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true; trap - EXIT' EXIT

  git checkout "$BEFORE" -- "$stack/" 2>/dev/null || git checkout "$BEFORE" -- "$stack" 2>/dev/null || true

  if [ "$stack" = "root" ]; then
    git checkout "$BEFORE" -- docker-compose.yml 2>/dev/null || true
    docker compose up -d --force-recreate 2>&1 | while read -r line; do log "$line"; done
  elif needs_build "$stack"; then
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" build 2>&1 | tail -3 | while read -r line; do log "$line"; done
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d --force-recreate 2>&1 | while read -r line; do log "$line"; done
  else
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d --force-recreate 2>&1 | while read -r line; do log "$line"; done
  fi

  # Restore working tree to HEAD
  git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true
  trap - EXIT  # restore completed normally; clear the safety trap

  ROLLED_BACK="$ROLLED_BACK $stack"
  warn "$stack rolled back to ${BEFORE:0:7}"
}

# ── Deploy Each Stack ─────────────────────────────────
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

# ── Config Reloads (hot-reload without restart) ───────
if [ "$PROMETHEUS_RELOAD" = true ]; then
  info "Reloading Prometheus config..."
  if docker exec prometheus kill -SIGHUP 1 2>/dev/null; then
    ok "Prometheus config reloaded"
    CONFIG_RELOADS="$CONFIG_RELOADS prometheus"
  else
    warn "Prometheus reload failed (container may have restarted with stack)"
  fi
fi

if [ "$ALERTMANAGER_RELOAD" = true ]; then
  info "Reloading Alertmanager config..."
  if docker exec alertmanager kill -SIGHUP 1 2>/dev/null; then
    ok "Alertmanager config reloaded"
    CONFIG_RELOADS="$CONFIG_RELOADS alertmanager"
  else
    warn "Alertmanager reload failed (container may have restarted with stack)"
  fi
fi

# ── Config Sync (always run) ──────────────────────────
# Config-sync is idempotent — it compares local JSON against live APIs and only
# pushes the delta (including deletes). Running every deploy ensures configs are
# applied regardless of how the commit arrived (remote push, local push, etc.).
#
# If any stack was rolled back, use the previous commit's config data so the
# API state matches the rolled-back containers (not HEAD's potentially broken config).
CONFIG_SYNC_OK=false
CONFIG_SYNC_ROLLED_BACK=false
if [ -n "$CONFIG_SYNC_STACK" ] && [ -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" ] && [ -d "$REPO_DIR/configs/data" ]; then
  info "Running config-sync..."

  if [ -n "$ROLLED_BACK" ]; then
    warn "Stacks were rolled back — using config data from ${BEFORE:0:7}"
    git checkout "$BEFORE" -- configs/data/ 2>/dev/null || true
    CONFIG_SYNC_ROLLED_BACK=true
  fi

  # Rebuild image if sync engine code changed
  if echo "$CHANGED" | grep -q '^configs/sync/\|^configs/Dockerfile'; then
    log "Building config-sync image..."
    docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" build config-sync 2>&1 | tail -5 | while read -r line; do log "$line"; done
  fi

  # Always force-recreate the one-shot container (data is bind-mounted,
  # so the image hash doesn't change on data-only updates)
  docker rm -f config-sync 2>/dev/null || true
  docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" up -d config-sync 2>&1 | while read -r line; do log "$line"; done

  # Wait for it to finish
  sync_wait=0
  while [ $sync_wait -lt 120 ]; do
    running=$(docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" ps --status=running --format '{{.Name}}' 2>/dev/null | grep -c 'config-sync' || true)
    if [ "$running" -eq 0 ]; then break; fi
    sleep 5
    sync_wait=$((sync_wait + 5))
  done

  # Check exit code
  exit_code=$(docker inspect config-sync --format '{{.State.ExitCode}}' 2>/dev/null || echo "1")
  if [ "$exit_code" = "0" ]; then
    ok "config-sync completed"
    CONFIG_SYNC_OK=true
  else
    warn "config-sync exited with code $exit_code"
    docker logs config-sync --tail 20 2>&1 | while read -r line; do log "  $line"; done
  fi

  # Restore HEAD's config data if we rolled back for sync
  if [ "$CONFIG_SYNC_ROLLED_BACK" = true ]; then
    git checkout "$AFTER" -- configs/data/ 2>/dev/null || true
  fi
  sep
fi

# ── Summary ───────────────────────────────────────────
sep
info "Deploy Summary (${BEFORE:0:7} → ${AFTER:0:7})"

if [ -n "$SUCCEEDED" ]; then
  ok "Deployed:$SUCCEEDED"
fi
if [ -n "$CONFIG_RELOADS" ]; then
  ok "Config reloaded:$CONFIG_RELOADS"
fi
if [ -n "$SCRIPT_CHANGES" ]; then
  log "📝 Scripts updated (no restart needed):$SCRIPT_CHANGES"
fi
if [ "$CONFIG_SYNC_OK" = true ]; then
  ok "Config sync: applied"
fi
if [ -n "$ROLLED_BACK" ]; then
  warn "Rolled back:$ROLLED_BACK"
fi
if [ -n "$FAILED" ]; then
  err "Failed:$FAILED"
  exit 1
fi

info "Deploy complete."
