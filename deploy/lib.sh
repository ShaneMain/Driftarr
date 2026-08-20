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

# ── Deploy lock ───────────────────────────────────────
# Shared with configs/run-export.sh (the export cron must not commit while a
# deploy has configs/ or a stack dir checked out at BEFORE). deploy.sh takes
# the lock before sourcing this file, so it defines the same default itself;
# keep the two in sync.
DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-$REPO_DIR/.deploy.lock}"

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
  compose_cmd "$stack_dir" ps --format '{{.Name}} {{.Status}}' 2>/dev/null || true
}

# Machine-readable container table for the deploy gates: one container per
# line, tab-separated "name state health exitcode". The gates test the STATE
# and HEALTH columns exactly — never the human "Status" string, and never the
# name — so a container called uptime-kuma, backup or syncthing can't satisfy
# (or trip) a match meant for "Up"/"healthy"/"sync".
# Usage: container_table <stack> [extra ps args...]   e.g. container_table media -a
container_table() {
  local stack="$1"; shift
  compose_cmd "$stack" ps "$@" --format $'{{.Name}}\t{{.State}}\t{{.Health}}\t{{.ExitCode}}' 2>/dev/null || true
}

# One-shot services (config-sync, db-migrate, ...) are expected to exit; the
# deploy waits for them instead of treating "exited" as a failure. Matched on
# whole name components so "syncthing" or "rsync-server" are NOT one-shots.
is_oneshot_name() {
  [[ "$1" =~ (^|[-_])(sync|oneshot|migrate)([-_]|$) ]]
}

# ── Stack enumeration ─────────────────────────────────
# The root docker-compose.yml `include:` list is the on/off switch for stacks:
# commenting a stack out there must stop the pipeline deploying it (and drift
# detection re-adding it). Prints enabled stack names, one per line. Accepted
# entry forms (quotes optional, comments stripped, leading ./ normalised):
#   - media/docker-compose.yml         - ./media/docker-compose.yml
#   - path: media/docker-compose.yml   - path:
#                                          media/docker-compose.yml
#   include: [media/docker-compose.yml, dns/docker-compose.yml]
# The stack name is the compose file's parent directory relative to REPO_DIR
# (so nested "stacks/media/docker-compose.yml" yields "stacks/media").
# Falls back to every top-level dir holding a docker-compose.yml when the root
# file has no include: block — or, with a loud warning, when the block parses
# to nothing (a syntax the parser doesn't know must not deploy NOTHING).
_glob_stacks() {
  local d
  for d in "$REPO_DIR"/*/; do
    [ -f "$d/docker-compose.yml" ] && basename "$d"
  done
}

enabled_stacks() {
  local root="$REPO_DIR/docker-compose.yml" parsed
  if [ -f "$root" ] && grep -qE '^include:' "$root"; then
    parsed=$(awk '
      function emit(line,   m) {
        gsub(/#.*/, "", line)                                # strip comments
        while (match(line, /[A-Za-z0-9._\/-]*docker-compose\.ya?ml/)) {
          m = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          sub(/\/?docker-compose\.ya?ml$/, "", m)          # parent dir
          sub(/^\.\//, "", m)                               # leading ./
          if (m != "" && m != ".") print m
        }
      }
      /^include:/ {
        if ($0 ~ /^include:[[:space:]]*\[/) { emit($0); inblock=0 } else inblock=1
        next
      }
      inblock && /^[^[:space:]#]/ { inblock=0 }               # next top-level key
      inblock { emit($0) }
    ' "$root" | awk '!seen[$0]++')
    if [ -n "$parsed" ]; then
      printf '%s\n' "$parsed"
    else
      warn "root docker-compose.yml has an include: block but no parsable stack entries — falling back to every */docker-compose.yml"
      _glob_stacks
    fi
  else
    _glob_stacks
  fi
}

# Is <stack> in the enabled set? (exact name match)
stack_enabled() {
  enabled_stacks | grep -qx "$1"
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
    # `if`, not `[ -f ] &&`: a missing common.yml must not make the brace group
    # exit 1 and (via pipefail + errexit) abort the whole deploy silently.
    if [ -f "$REPO_DIR/common.yml" ]; then md5sum "$REPO_DIR/common.yml"; fi
  } 2>/dev/null | sort | md5sum | awk '{print $1}'
}
