#!/usr/bin/env bash
# deploy/40-crontab.sh — declarative crontab sync
# Writes: CRONTAB_OK

CRONTAB_FILE="$REPO_DIR/crontab"
if [ -f "$CRONTAB_FILE" ]; then
  CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)
  NEW_CRONTAB=$(cat "$CRONTAB_FILE")
  if [ "$CURRENT_CRONTAB" != "$NEW_CRONTAB" ]; then
    info "Installing updated crontab..."
    crontab "$CRONTAB_FILE"
    ok "Crontab updated"
    CRONTAB_OK=true
  else
    log "Crontab unchanged — skipping"
    CRONTAB_OK=true
  fi
fi
sep
