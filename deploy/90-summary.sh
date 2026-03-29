#!/usr/bin/env bash
# deploy/90-summary.sh — deploy summary
# Reads all state variables set by previous modules

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
if [ "$CRONTAB_OK" = true ]; then
  ok "Crontab: synced"
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
