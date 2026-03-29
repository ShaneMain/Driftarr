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
