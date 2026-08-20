#!/usr/bin/env bash
# deploy/10-detect.sh — change detection, stack discovery, drift detection
# Reads: CHANGED, BEFORE, AFTER
# Sets: STACKS, CONFIG_CHANGES, hot-reload flags

# ── Auto-discover stacks from changed file paths ─────
# Only stacks listed in the root docker-compose.yml `include:` block are
# deployable (see enabled_stacks in lib.sh) — commenting a stack out there is
# the documented way to disable it, and used to be ignored here because
# discovery went by filesystem glob. Disabled stacks with changes are logged
# once and skipped; they are also excluded from the fan-out and from drift.
ENABLED_STACKS=$(enabled_stacks | tr '\n' ' ' | xargs)
DISABLED_SKIPPED=""
STACKS=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(echo "$file" | cut -d/ -f1)
  if [ -f "$REPO_DIR/$dir/docker-compose.yml" ] 2>/dev/null; then
    if echo " $ENABLED_STACKS " | grep -q " $dir "; then
      STACKS="$STACKS $dir"
    else
      case " $DISABLED_SKIPPED " in *" $dir "*) ;; *)
        log "Skipping $dir — not in root docker-compose.yml include: list (disabled)"
        DISABLED_SKIPPED="$DISABLED_SKIPPED $dir" ;;
      esac
    fi
  fi
  # Root common.yml affects all stacks
  if [ "$file" = "common.yml" ]; then
    STACKS="$STACKS $ENABLED_STACKS"
  fi
  # Root docker-compose.yml affects all stacks. Deploy each with its own
  # project (-p <stack>) rather than one merged repo-root project — a root
  # `docker compose up` claims the same container_names under a different
  # project name, causing "name already in use" conflicts with the per-stack
  # projects that normally own them.
  if [ "$file" = "docker-compose.yml" ]; then
    STACKS="$STACKS $ENABLED_STACKS"
  fi
  # deploy/ module changes don't trigger stack deploys (they're sourced fresh)
done <<< "$CHANGED"

STACKS=$(echo "$STACKS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

# ── Drift Detection ──────────────────────────────────
DEPLOY_HASHES_DIR="$REPO_DIR/.deploy-hashes"
mkdir -p "$DEPLOY_HASHES_DIR"
DRIFT_STACKS=""
for stack in $ENABLED_STACKS; do
  d="$REPO_DIR/$stack"
  [ -f "$d/docker-compose.yml" ] || continue
  repo_hash=$(stack_file_hash "$d")
  stored_hash=$(cat "$DEPLOY_HASHES_DIR/$stack" 2>/dev/null || echo "")
  if [ "$repo_hash" != "$stored_hash" ]; then
    if ! echo " $STACKS " | grep -q " $stack "; then
      log "Drift detected in $stack (file checksums changed since last deploy)"
      DRIFT_STACKS="$DRIFT_STACKS $stack"
    fi
  fi
done
STACKS="$STACKS $DRIFT_STACKS"
STACKS=$(echo "$STACKS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

# ── Log Changed Files ─────────────────────────────────
info "Changed files:"
while IFS= read -r file; do
  [ -z "$file" ] && continue
  log "  $file"
done <<< "$CHANGED"
sep

# ── Categorize Changes ────────────────────────────────
# Hot-reload detection now reads from stack.conf patterns instead of hardcoding.
# Legacy: still detect Prometheus/Alertmanager for backward compatibility with
# stacks that don't have a stack.conf yet.
PROMETHEUS_RELOAD=false
ALERTMANAGER_RELOAD=false
CONFIG_CHANGES=false

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    monitoring/prometheus.yml|monitoring/alert-rules.yml) PROMETHEUS_RELOAD=true ;;
    monitoring/alertmanager.yml) ALERTMANAGER_RELOAD=true ;;
    configs/*) CONFIG_CHANGES=true ;;
    */*.sh) SCRIPT_CHANGES="$SCRIPT_CHANGES ${file##*/}" ;;
  esac
done <<< "$CHANGED"

# ── Hot-reload vs deploy ──────────────────────────────
# A stack is downgraded from deploy to hot-reload (30-reload.sh) only if EVERY
# changed file in it matches its STACK_HOT_RELOAD_PATTERNS — a compose or
# script change alongside a reloadable config still needs a real deploy.
# Drift-detected stacks (no changed files) always deploy.
for stack in $STACKS; do
  [ "$stack" = "root" ] && continue
  [ -f "$REPO_DIR/$stack/stack.conf" ] || continue
  patterns=$(stack_hot_reload_patterns "$stack")
  [ -z "$patterns" ] && continue
  stack_changed=false
  all_reloadable=true
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      "$stack"/*) ;;
      *) continue ;;
    esac
    stack_changed=true
    rel_path="${file#"$stack"/}"
    matched=false
    # set -f: the unquoted $patterns split must NOT glob-expand against the
    # cwd (REPO_DIR) — "*.yml" would otherwise become "common.yml docker-compose.yml"
    # and never match prometheus.yml, silently promoting a reload to a restart.
    set -f
    for pattern in $patterns; do
      # shellcheck disable=SC2254
      case "$rel_path" in
        $pattern) matched=true ;;
      esac
    done
    set +f
    [ "$matched" = false ] && all_reloadable=false
  done <<< "$CHANGED"
  if [ "$stack_changed" = true ] && [ "$all_reloadable" = true ]; then
    # `grep -v` exits 1 when it filters out the LAST remaining stack (a commit
    # touching only hot-reloadable files, e.g. a lone Caddyfile). Under the
    # sourced `set -euo pipefail`, that non-zero pipeline would fail the
    # assignment and abort the whole deploy. Swallow grep's no-match status so
    # STACKS can legitimately become empty.
    STACKS=$(echo "$STACKS" | tr ' ' '\n' | { grep -v "^${stack}$" || true; } | tr '\n' ' ' | xargs)
  fi
done

# ── Log Config Diffs ──────────────────────────────────
if [ "$CONFIG_CHANGES" = true ]; then
  info "Config file changes:"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      configs/data/*/*.json)
        log "  📋 $file"
        git diff "$BEFORE" "$AFTER" -- "$file" | grep '^[+-]' | grep -v '^[+-][+-][+-]' | head -30 | while read -r line; do
          log "    $line"
        done || true
        ;;
      configs/sync/*.py|configs/sync/modules/*.py)
        log "  📝 $file (sync engine updated)"
        ;;
      configs/Dockerfile)
        log "  🐳 $file (container build changed)"
        ;;
    esac
  done <<< "$CHANGED"
  sep
fi

if [ -n "$STACKS" ]; then
  info "Stacks to deploy: $STACKS"
fi
sep
