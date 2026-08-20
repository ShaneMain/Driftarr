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

# Which revision of configs/data/ to apply?
# Only the stack that HOSTS config-sync matters: if it was rolled back, its
# services are running BEFORE's compose, so apply BEFORE's declared config to
# match. A rollback of any OTHER stack (dns, proxy, ...) says nothing about the
# *arr services — applying BEFORE there would silently undo the user's intended
# config change, and the export cron would then commit that reverted state
# back to git as an "auto-export". So: revert only for CONFIG_SYNC_STACK
# (including the "(stopped)" marker), otherwise apply AFTER normally.
case " $ROLLED_BACK " in
  *" $CONFIG_SYNC_STACK "*|*" $CONFIG_SYNC_STACK(stopped) "*)
    warn "$CONFIG_SYNC_STACK was rolled back — using config data from ${BEFORE:0:7}"
    git checkout "$BEFORE" -- configs/data/ 2>/dev/null || true
    CONFIG_SYNC_ROLLED_BACK=true
    ;;
esac

# Every compose/docker pipeline below is status-checked explicitly: these run
# at module top level under errexit+pipefail, so an unguarded failure would
# abort the run before 90-summary (no .deploy-log line, FAILED not reported).
# The `&& rc=0 || rc=${PIPESTATUS[0]}` form keeps errexit from firing on the
# pipeline while still capturing docker's own status (not tail's).
_sync_rc=0

# Rebuild image if sync engine code changed
if echo "$CHANGED" | grep -q '^configs/sync/\|^configs/Dockerfile'; then
  log "Building config-sync image..."
  docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" build config-sync 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10 \
    && _sync_rc=0 || _sync_rc=${PIPESTATUS[0]}
  [ "$_sync_rc" -eq 0 ] || err "config-sync image build failed (exit $_sync_rc)"
fi

# Force-recreate the one-shot container (data is bind-mounted)
if [ "$_sync_rc" -eq 0 ]; then
  docker rm -f config-sync 2>/dev/null || true
  docker compose -p "$CONFIG_SYNC_STACK" -f "$REPO_DIR/$CONFIG_SYNC_STACK/docker-compose.yml" up -d config-sync 2>&1 | tee -a >(logger -t "$LOG_TAG") | tail -10 \
    && _sync_rc=0 || _sync_rc=${PIPESTATUS[0]}
  [ "$_sync_rc" -eq 0 ] || err "could not start config-sync (exit $_sync_rc)"
fi

# Block on the container until it actually exits. `docker wait` is the only
# safe signal: polling `docker inspect .State.ExitCode` returns 0 while the
# container is still running (ExitCode defaults to int-zero), which silently
# reports success for a stuck run.
#
# The timeout must exceed sync.py's worst-case reachability window
# (REACHABILITY_ATTEMPTS × (WAIT + BACKOFF) ≈ 5 min at today's defaults)
# plus handshake + module work. 10 min covers it with headroom.
#
# (Config-sync is end-to-end or it fails: a timeout is a deploy failure.)
CONFIG_SYNC_TIMEOUT="${CONFIG_SYNC_TIMEOUT:-600}"
if [ "$_sync_rc" -ne 0 ]; then
  FAILED="$FAILED config-sync"
elif log "Waiting up to ${CONFIG_SYNC_TIMEOUT}s for config-sync to finish..." \
     && exit_code=$(timeout "$CONFIG_SYNC_TIMEOUT" docker wait config-sync 2>/dev/null) && [ -n "$exit_code" ]; then
  if [ "$exit_code" = "0" ]; then
    ok "config-sync completed"
    CONFIG_SYNC_OK=true
  else
    err "config-sync exited with code $exit_code — declared config did not apply"
    { docker logs config-sync --tail 30 2>&1 || true; } | while read -r line; do log "  $line"; done
    FAILED="$FAILED config-sync"
  fi
else
  err "config-sync did not exit within ${CONFIG_SYNC_TIMEOUT}s — killing container"
  { docker logs config-sync --tail 30 2>&1 || true; } | while read -r line; do log "  $line"; done
  docker kill config-sync 2>/dev/null || true
  FAILED="$FAILED config-sync"
fi
unset _sync_rc

# Restore HEAD's config data if we rolled back for sync
if [ "$CONFIG_SYNC_ROLLED_BACK" = true ]; then
  git checkout "$AFTER" -- configs/data/ 2>/dev/null || true
fi
sep
