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

  # Pre-pull images with retries — separates transient registry failures
  # (retryable, zero downtime) from real deploy failures (rollback). Non-fatal:
  # `up` can still succeed on cached images if the registry stays down.
  # Skipped for build stacks (their images aren't pullable) and the legacy
  # root path.
  if [ "$stack" != "root" ] && ! needs_build "$stack"; then
    local pull_ok=false attempt
    for attempt in 1 2 3; do
      if compose_cmd "$stack" pull --quiet 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -5; then
        pull_ok=true
        break
      fi
      warn "Image pull failed (attempt $attempt/3) — retrying in $((attempt * 5))s..."
      sleep $((attempt * 5))
    done
    [ "$pull_ok" = true ] || warn "Pre-pull failed after 3 attempts — proceeding with cached images"
  fi

  # Capture docker's own exit status via PIPESTATUS[0] (the pipeline ends in
  # `tail`, and deploy_stack runs with errexit suppressed because it's called
  # as an `if` condition — so a failed `up`/`build` would otherwise fall
  # straight through to the health gate and, if old containers are still up or
  # nothing was created, be recorded as SUCCESS).
  local up_rc=0
  if [ "$stack" = "root" ]; then
    # Legacy path — 10-detect.sh now expands root compose changes into
    # per-stack deploys, so this only runs if "root" is passed explicitly.
    log "Root compose changed — updating all services"
    docker compose up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
    up_rc=${PIPESTATUS[0]}
  elif needs_build "$stack"; then
    log "Building $stack images..."
    compose_cmd "$stack" build 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10
    up_rc=${PIPESTATUS[0]}
    if [ "$up_rc" -eq 0 ]; then
      log "Starting $stack..."
      compose_cmd "$stack" up -d --remove-orphans 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
      up_rc=${PIPESTATUS[0]}
    fi
  else
    compose_cmd "$stack" up -d --remove-orphans 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
    up_rc=${PIPESTATUS[0]}
  fi
  if [ "$up_rc" -ne 0 ]; then
    warn "compose build/up failed for $stack (exit $up_rc) — treating as deploy failure"
    return 1
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
    # Match the healthcheck grace state specifically — a bare 'starting' also
    # matches "Restarting (1)...", letting crash-looping containers pass as
    # still-starting (found via caddy crash-loop, 2026-07)
    if ! echo "$current_state" | grep -qi 'health: starting'; then
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

  # A non-root stack with zero containers after `up` means the compose produced
  # nothing (interpolation error, missing external network, ...). The grep-based
  # health gate below passes vacuously on empty input, so guard it explicitly.
  if [ "$stack" != "root" ] && [ -z "$after_state" ]; then
    warn "No containers found for $stack after deploy — nothing was created"
    return 1
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
  exited=$(echo "$after_state" | grep -ivE '(running|healthy|Up|health: starting|Exited \(0\))' || true)
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

  # A stack that didn't exist at BEFORE can't be rolled back — checking out
  # its old (nonexistent) files would silently redeploy the same broken
  # version. Take it down instead.
  if [ "$stack" != "root" ] && ! git cat-file -e "$BEFORE:$stack" 2>/dev/null; then
    warn "$stack did not exist at ${BEFORE:0:7} — stopping it instead of rolling back"
    compose_cmd "$stack" down 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -5 || true
    ROLLED_BACK="$ROLLED_BACK $stack(stopped)"
    return
  fi

  warn "Rolling back $stack to ${BEFORE:0:7}..."

  # Preserve any EXIT handler already installed by the entrypoint (e.g. the
  # deploy-failure notifier). The safety trap below and its teardown must
  # restore it, not clear it — otherwise a run that rolls back disarms the
  # notifier and every subsequent failure (including 90-summary's exit 1) goes
  # unreported.
  local prev_exit_trap
  prev_exit_trap=$(trap -p EXIT)

  trap 'git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true; trap - EXIT' EXIT

  git checkout "$BEFORE" -- "$stack/" 2>/dev/null || git checkout "$BEFORE" -- "$stack" 2>/dev/null || true

  if [ "$stack" = "root" ]; then
    git checkout "$BEFORE" -- docker-compose.yml 2>/dev/null || true
    docker compose up -d 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  elif needs_build "$stack"; then
    compose_cmd "$stack" build 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10
    compose_cmd "$stack" up -d --remove-orphans 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  else
    compose_cmd "$stack" up -d --remove-orphans 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -20
  fi

  _recover_created_containers "$stack"

  git checkout "$AFTER" -- "$stack/" 2>/dev/null || git checkout "$AFTER" -- "$stack" 2>/dev/null || true
  eval "${prev_exit_trap:-trap - EXIT}"

  ROLLED_BACK="$ROLLED_BACK $stack"
  warn "$stack rolled back to ${BEFORE:0:7}"

  # Verify the rollback actually came up — "rolled back" must not silently
  # mean "rolled back to something also broken".
  sleep 10
  local rb_state rb_bad
  rb_state=$(snapshot_containers "$stack")
  rb_bad=$(echo "$rb_state" | grep -iE 'unhealthy|restarting|created' || true)
  if [ -n "$rb_bad" ]; then
    err "$stack is still unhealthy AFTER rollback — needs manual attention:"
    echo "$rb_bad" | while read -r line; do err "  $line"; done
  fi
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
