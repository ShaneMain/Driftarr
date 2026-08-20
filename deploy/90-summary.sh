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

# Persistent audit trail (survives journald rotation): one line per run and the
# SHA the pipeline last processed. Server-local state (gitignored). Written
# before the failure exit so failed runs are recorded too.
_outcome="SUCCEEDED"
[ -n "$ROLLED_BACK" ] && _outcome="ROLLED_BACK"
[ -n "$FAILED" ] && _outcome="FAILED"
printf '%s\t%s..%s\t%s\n' "$(date -Is 2>/dev/null || date)" "${BEFORE:0:7}" "${AFTER:0:7}" "$_outcome" \
  >> "$REPO_DIR/.deploy-log" 2>/dev/null || true
# .last-deployed only advances on a fully clean run: 00-pull uses it as BEFORE,
# so a failed or rolled-back stack stays inside the next run's diff range and
# is retried instead of being forgotten.
if [ -z "$FAILED" ] && [ -z "$ROLLED_BACK" ]; then
  printf '%s\n' "$AFTER" > "$REPO_DIR/.last-deployed" 2>/dev/null || true
fi

if [ -n "$FAILED" ]; then
  err "Failed:$FAILED"
  exit 1
fi

info "Deploy complete."
