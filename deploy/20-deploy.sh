#!/usr/bin/env bash
# deploy/20-deploy.sh — deploy and rollback logic for each stack
# Reads: STACKS, BEFORE, AFTER, BUILD_STACKS
# Writes: SUCCEEDED, FAILED, ROLLED_BACK

# ── Static-IP race recovery ─────────────────────────
# `docker compose up -d` recreates containers atomically (stop → rm →
# create → start) but the kernel network namespace cleanup is async.
# For services with a fixed ipv4_address the new container tries to bind
# an IP the old namespace hasn't released yet, leaving it in `created`
# state with "Address already in use". Docker's restart policy does not
# recover `created` state.
#
# After every `up -d`, check for containers stuck in `created` state
# and retry with increasing backoff. The IP typically frees within 2-5s
# once the old namespace is torn down.

_recover_created_containers() {
  local stack="$1"
  local created_containers retry max_retries=6
  for retry in $(seq 1 "$max_retries"); do
    if [ "$stack" = "root" ]; then
      created_containers=$(docker compose ps -a --status=created --format '{{.Name}}' 2>/dev/null || true)
    else
      created_containers=$(docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" ps -a --status=created --format '{{.Name}}' 2>/dev/null || true)
    fi
    [ -z "$created_containers" ] && return 0
    if [ "$retry" -eq 1 ]; then
      warn "Containers stuck in 'created' state — retrying with backoff:"
    fi
    local wait=$(( retry * 2 ))   # 2, 4, 6, 8, 10, 12s
    log "  attempt $retry/$max_retries (waiting ${wait}s for IP release)..."
    sleep "$wait"
    echo "$created_containers" | while read -r cname; do
      [ -z "$cname" ] && continue
      log "  starting $cname..."
      docker start "$cname" 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -3 || true
    done
  done
  # Final check — log any survivors
  if [ "$stack" = "root" ]; then
    created_containers=$(docker compose ps -a --status=created --format '{{.Name}}' 2>/dev/null || true)
  else
    created_containers=$(docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" ps -a --status=created --format '{{.Name}}' 2>/dev/null || true)
  fi
  if [ -n "$created_containers" ]; then
    warn "Containers still stuck after $max_retries retries:"
    echo "$created_containers" | while read -r cname; do warn "  $cname"; done
  fi
}

deploy_stack() {
  local stack="$1"
  local timeout
  timeout=$(stack_health_timeout "$stack")
  info "Deploying: $stack"

  # Run pre-deploy hook if present
  local pre_hook="$REPO_DIR/$stack/pre-deploy.sh"
  if [ -x "$pre_hook" ]; then
    log "Running pre-deploy hook..."
    if ! "$pre_hook"; then
      warn "pre-deploy.sh failed for $stack"
      return 1
    fi
  fi

  # Snapshot before
  local before_state
  before_state=$(snapshot_containers "$stack")
  if [ -n "$before_state" ]; then
    log "Before:"
    echo "$before_state" | while read -r line; do log "  $line"; done
  fi

  if [ "$stack" = "root" ]; then
    log "Root compose changed — updating all services"
    docker compose up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  elif needs_build "$stack"; then
    log "Building $stack images..."
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" build 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10
    log "Starting $stack..."
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  else
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  fi

  # Recover from static-IP recreation race
  _recover_created_containers "$stack"

  # Wait for health checks to settle
  log "Waiting for health checks to settle..."
  local health_wait=0
  while [ $health_wait -lt "$timeout" ]; do
    sleep 10
    health_wait=$((health_wait + 10))
    local current_state
    current_state=$(snapshot_containers "$stack")
    if ! echo "$current_state" | grep -qi 'starting'; then
      break
    fi
    [ $((health_wait % 30)) -eq 0 ] && log "Still waiting for health checks... (${health_wait}s)"
  done

  # Wait for one-shot containers to finish
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

  # Snapshot after
  local after_state
  after_state=$(snapshot_containers "$stack")
  if [ -n "$after_state" ]; then
    log "After:"
    echo "$after_state" | while read -r line; do log "  $line"; done
  fi

  # Health checks
  local unhealthy
  unhealthy=$(echo "$after_state" | grep -i 'unhealthy' || true)
  if [ -n "$unhealthy" ]; then
    warn "Unhealthy containers detected in $stack:"
    echo "$unhealthy" | while read -r line; do warn "  $line"; done
    return 1
  fi

  local exited
  exited=$(echo "$after_state" | grep -ivE '(running|healthy|Up|starting|Exited \(0\))' || true)
  if [ -n "$exited" ]; then
    warn "Non-running containers detected in $stack:"
    echo "$exited" | while read -r line; do warn "  $line"; done
    return 1
  fi

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

  # Run post-deploy hook if present
  local post_hook="$REPO_DIR/$stack/post-deploy.sh"
  if [ -x "$post_hook" ]; then
    log "Running post-deploy hook..."
    if ! "$post_hook"; then
      warn "post-deploy.sh failed for $stack (non-fatal)"
    fi
  fi

  ok "$stack deployed successfully"

  # Store file checksum for drift detection
  stack_file_hash "$REPO_DIR/$stack" > "$DEPLOY_HASHES_DIR/$stack"

  return 0
}

rollback_stack() {
  local stack="$1"
  warn "Rolling back $stack to ${BEFORE:0:7}..."

  trap 'git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true; trap - EXIT' EXIT

  git checkout "$BEFORE" -- "$stack/" 2>/dev/null || git checkout "$BEFORE" -- "$stack" 2>/dev/null || true

  if [ "$stack" = "root" ]; then
    git checkout "$BEFORE" -- docker-compose.yml 2>/dev/null || true
    docker compose up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  elif needs_build "$stack"; then
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" build 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  else
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  fi

  _recover_created_containers "$stack"

  git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true
  trap - EXIT

  ROLLED_BACK="$ROLLED_BACK $stack"
  warn "$stack rolled back to ${BEFORE:0:7}"
}

# ── Deploy Loop ───────────────────────────────────────
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
