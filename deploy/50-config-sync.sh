#!/usr/bin/env bash
# deploy/50-config-sync.sh — run config-sync one-shot container
# Reads: CONFIG_SYNC_STACK, CHANGED, ROLLED_BACK, BEFORE, AFTER
# Writes: CONFIG_SYNC_OK

CONFIG_SYNC_OK=false
CONFIG_SYNC_ROLLED_BACK=false

if [ -z "$CONFIG_SYNC_STACK" ] || [ ! -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" ] || [ ! -d "$REPO_DIR/configs/data" ]; then
  return 0 2>/dev/null || true
fi

info "Running config-sync..."

if [ -n "$ROLLED_BACK" ]; then
  warn "Stacks were rolled back — using config data from ${BEFORE:0:7}"
  git checkout "$BEFORE" -- configs/data/ 2>/dev/null || true
  CONFIG_SYNC_ROLLED_BACK=true
fi

# Rebuild image if sync engine code changed
if echo "$CHANGED" | grep -q '^configs/sync/\|^configs/Dockerfile'; then
  log "Building config-sync image..."
  docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" build config-sync 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10
fi

# Force-recreate the one-shot container (data is bind-mounted)
docker rm -f config-sync 2>/dev/null || true
docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" up -d config-sync 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10

# Block on the container until it actually exits. `docker wait` is the only
# safe signal: polling `docker inspect .State.ExitCode` returns 0 while the
# container is still running (ExitCode defaults to int-zero), which silently
# reports success for a stuck run.
#
# The timeout must exceed sync.py's worst-case reachability window
# (REACHABILITY_ATTEMPTS × (WAIT + BACKOFF) ≈ 5 min at today's defaults)
# plus handshake + module work. 10 min covers it with headroom.
#
# See driftarr-spec/config-sync-engine.md §Core Principles #6.
CONFIG_SYNC_TIMEOUT="${CONFIG_SYNC_TIMEOUT:-600}"
log "Waiting up to ${CONFIG_SYNC_TIMEOUT}s for config-sync to finish..."
if exit_code=$(timeout "$CONFIG_SYNC_TIMEOUT" docker wait config-sync 2>/dev/null) && [ -n "$exit_code" ]; then
  if [ "$exit_code" = "0" ]; then
    ok "config-sync completed"
    CONFIG_SYNC_OK=true
  else
    err "config-sync exited with code $exit_code — declared config did not apply"
    docker logs config-sync --tail 30 2>&1 | while read -r line; do log "  $line"; done
    FAILED="$FAILED config-sync"
  fi
else
  err "config-sync did not exit within ${CONFIG_SYNC_TIMEOUT}s — killing container"
  docker logs config-sync --tail 30 2>&1 | while read -r line; do log "  $line"; done
  docker kill config-sync 2>/dev/null || true
  FAILED="$FAILED config-sync"
fi

# Restore HEAD's config data if we rolled back for sync
if [ "$CONFIG_SYNC_ROLLED_BACK" = true ]; then
  git checkout "$AFTER" -- configs/data/ 2>/dev/null || true
fi
sep
