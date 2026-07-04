#!/usr/bin/env bash
# deploy/lib.sh — shared logging, helpers, and state for deploy modules
# Sourced by deploy.sh before any module runs. Do not execute directly.

# ── Logging ───────────────────────────────────────────
log()  { logger -t "$LOG_TAG" -- "$*"; echo "  $*"; }
info() { logger -t "$LOG_TAG" -- "$*"; echo "▶ $*"; }
ok()   { logger -t "$LOG_TAG" -- "OK: $*"; echo "  ✅ $*"; }
err()  { logger -t "$LOG_TAG" -- "FAIL: $*"; echo "  ❌ $*"; }
warn() { logger -t "$LOG_TAG" -- "WARN: $*"; echo "  ⚠️  $*"; }
sep()  { echo "────────────────────────────────────────"; }

# ── Deploy State (shared across modules) ──────────────
# Modules append to these; 90-summary.sh reads them.
SUCCEEDED=""
FAILED=""
ROLLED_BACK=""
CONFIG_RELOADS=""
SCRIPT_CHANGES=""
CRONTAB_OK=false
CONFIG_SYNC_OK=false

# ── Stack Configuration ──────────────────────────────
# Read a stack.conf value with a default fallback.
# Usage: stack_conf <stack_dir> <key> <default>
#   stack_conf monitoring STACK_BUILD_REQUIRED no
stack_conf() {
  local stack="$1" key="$2" default="${3:-}"
  local conf="$REPO_DIR/$stack/stack.conf"
  if [ -f "$conf" ]; then
    local val
    val=$(grep "^${key}=" "$conf" 2>/dev/null | head -1 | cut -d= -f2-)
    # Strip optional surrounding double quotes — the values are used in glob
    # matches and eval'd commands, where literal quotes silently break both
    val="${val%\"}"
    val="${val#\"}"
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

# Check if a stack needs docker compose build
needs_build() {
  local stack="$1"
  # stack.conf takes precedence over the global BUILD_STACKS variable
  local conf_val
  conf_val=$(stack_conf "$stack" STACK_BUILD_REQUIRED "")
  if [ -n "$conf_val" ]; then
    [ "$conf_val" = "yes" ]
    return
  fi
  # Fall back to global BUILD_STACKS
  echo "$BUILD_STACKS" | tr ' ' '\n' | grep -qx "$stack"
}

# Get health check timeout for a stack (default: 90s)
stack_health_timeout() {
  local stack="$1"
  stack_conf "$stack" STACK_HEALTH_TIMEOUT 90
}

# Get hot-reload patterns for a stack (space-separated globs)
stack_hot_reload_patterns() {
  local stack="$1"
  stack_conf "$stack" STACK_HOT_RELOAD_PATTERNS ""
}

# Get hot-reload command for a stack
stack_hot_reload_cmd() {
  local stack="$1"
  stack_conf "$stack" STACK_HOT_RELOAD_CMD ""
}

# Get script category for a stack (for logging script changes)
stack_script_category() {
  local stack="$1"
  stack_conf "$stack" STACK_SCRIPT_CATEGORY ""
}

# ── Container Helpers ─────────────────────────────────
# Run docker compose scoped to a stack's project ("root" = repo-root project).
# Usage: compose_cmd <stack> <compose args...>
compose_cmd() {
  local stack="$1"; shift
  if [ "$stack" = "root" ]; then
    docker compose "$@"
  else
    docker compose -p "$stack" -f "$REPO_DIR/$stack/docker-compose.yml" "$@"
  fi
}

snapshot_containers() {
  local stack_dir="$1"
  if [ "$stack_dir" = "root" ]; then
    docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null || true
  else
    docker compose -p "$stack_dir" -f "$REPO_DIR/$stack_dir/docker-compose.yml" ps --format '{{.Name}} {{.Status}}' 2>/dev/null || true
  fi
}

# ── File Checksum (for drift detection) ───────────────
# Hashes git-TRACKED files only, recursively — subdirectories (config/,
# provisioning/, ...) count, but runtime data living inside stack dirs can't
# cause perpetual drift. Includes the root common.yml since all stacks extend
# it. docker-compose.yml is excluded: compose changes deploy via git-diff
# detection; drift covers everything else (scripts, configs, hooks).
stack_file_hash() {
  local stack_dir="$1"
  local rel="${stack_dir#"$REPO_DIR"/}"
  rel="${rel%/}"
  {
    git -C "$REPO_DIR" ls-files -z -- "$rel" \
      | grep -zv 'docker-compose\.yml$' \
      | (cd "$REPO_DIR" && xargs -0 -r md5sum)
    [ -f "$REPO_DIR/common.yml" ] && md5sum "$REPO_DIR/common.yml"
  } 2>/dev/null | sort | md5sum | awk '{print $1}'
}
