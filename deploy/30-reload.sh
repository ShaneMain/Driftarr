#!/usr/bin/env bash
# deploy/30-reload.sh — config hot-reloads (no container restart needed)
# Reads: CHANGED, PROMETHEUS_RELOAD, ALERTMANAGER_RELOAD
# Writes: CONFIG_RELOADS

# ── Legacy hot-reloads (backward compat) ──────────────
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

# ── stack.conf-driven hot-reloads ─────────────────────
# For stacks with STACK_HOT_RELOAD_CMD, check if any of their
# STACK_HOT_RELOAD_PATTERNS matched changed files and run the command.
while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(echo "$file" | cut -d/ -f1)
  [ -f "$REPO_DIR/$dir/stack.conf" ] || continue

  reload_cmd=$(stack_hot_reload_cmd "$dir")
  [ -z "$reload_cmd" ] && continue

  patterns=$(stack_hot_reload_patterns "$dir")
  [ -z "$patterns" ] && continue

  rel_path="${file#"$dir"/}"
  for pattern in $patterns; do
    # shellcheck disable=SC2254
    case "$rel_path" in
      $pattern)
        info "Hot-reloading $dir ($rel_path matched)..."
        if eval "$reload_cmd" 2>/dev/null; then
          ok "$dir config reloaded"
          CONFIG_RELOADS="$CONFIG_RELOADS $dir"
        else
          warn "$dir reload failed"
        fi
        # Only reload once per stack even if multiple files matched
        break 2
        ;;
    esac
  done
done <<< "$CHANGED"
