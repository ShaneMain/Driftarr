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
RELOADED_STACKS=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(echo "$file" | cut -d/ -f1)
  [ -f "$REPO_DIR/$dir/stack.conf" ] || continue

  # Reload each stack at most once, even if several of its files changed —
  # without breaking out of the loop over the OTHER stacks' changed files.
  case " $RELOADED_STACKS " in *" $dir "*) continue ;; esac

  reload_cmd=$(stack_hot_reload_cmd "$dir")
  [ -z "$reload_cmd" ] && continue

  patterns=$(stack_hot_reload_patterns "$dir")
  [ -z "$patterns" ] && continue

  rel_path="${file#"$dir"/}"
  # set -f: don't glob-expand the patterns against cwd (see 10-detect.sh)
  set -f
  for pattern in $patterns; do
    # shellcheck disable=SC2254
    case "$rel_path" in
      $pattern)
        info "Hot-reloading $dir ($rel_path matched)..."
        RELOADED_STACKS="$RELOADED_STACKS $dir"
        if eval "$reload_cmd" 2>/dev/null; then
          ok "$dir config reloaded"
          CONFIG_RELOADS="$CONFIG_RELOADS $dir"
          # Record the applied state so drift detection doesn't force a full
          # restart of this stack on the next deploy (the reloaded files are
          # part of stack_file_hash).
          if [ -n "${DEPLOY_HASHES_DIR:-}" ]; then
            stack_file_hash "$REPO_DIR/$dir" > "$DEPLOY_HASHES_DIR/$dir"
          fi
        else
          warn "$dir reload failed"
        fi
        break
        ;;
    esac
  done
  set +f
done <<< "$CHANGED"
