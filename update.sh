#!/usr/bin/env bash
set -euo pipefail

# ── driftarr updater ──────────────────────────────────
# Pulls updates from the upstream template repo without clobbering
# your local configuration.
#
# Usage:
#   ./update.sh              # Interactive — preview then apply
#   ./update.sh --check      # Just check for updates, don't apply
#   ./update.sh --apply      # Apply without interactive confirmation
#
# How it works:
#   1. Adds/fetches the upstream remote (ShaneMain/Driftarr)
#   2. Merges upstream/main with --allow-unrelated-histories (safe for template repos)
#   3. Core files (deploy engine, sync framework, CI) → always take upstream's version
#   4. User files (compose files, stack configs, .env) → always keep yours on conflict
#   5. New files from upstream → accepted automatically
#
# Core vs User file classification:
#   Core (upstream wins):  deploy.sh, setup.sh, update.sh, common.yml (root),
#                          .github/*, configs/sync/*, configs/Dockerfile,
#                          configs/run-export.sh, docs/*, LICENSE, README.md
#   User (yours wins):     docker-compose.yml (all), */common.yml (stack-level),
#                          */docker-compose.yml, monitoring/prometheus.yml,
#                          monitoring/alert-rules.yml, .env.example, .gitignore,
#                          configs/data/*

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▶${NC} $*"; }
ok()    { echo -e "${GREEN}  ✅${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠️${NC}  $*"; }
err()   { echo -e "${RED}  ❌${NC} $*"; }

UPSTREAM_URL="https://github.com/ShaneMain/Driftarr.git"
UPSTREAM_REMOTE="upstream"
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── Core files: upstream always wins on conflict ──────
# Patterns matched against the file path relative to repo root.
# Uses git pathspec / fnmatch-style matching.
CORE_PATTERNS=(
  "deploy.sh"
  "setup.sh"
  "update.sh"
  "common.yml"
  "LICENSE"
  "README.md"
  ".github/*"
  "configs/sync/*"
  "configs/Dockerfile"
  "configs/run-export.sh"
  "configs/__init__.py"
  "docs/*"
)

# ── Check if a file is "core" (upstream wins) ─────────
is_core_file() {
  local file="$1"
  for pattern in "${CORE_PATTERNS[@]}"; do
    # dir/* or dir/** → match anything under that directory (any depth)
    local prefix="${pattern%%/\**}"
    if [[ "$prefix" != "$pattern" && "$file" == "$prefix/"* ]]; then
      return 0
    fi
    # Exact match for non-glob patterns (e.g. "deploy.sh", "LICENSE")
    [[ "$file" == "$pattern" ]] && return 0
  done
  return 1
}

# ── Ensure we're in a git repo ─────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  err "Not inside a git repository. Run this from your project root."
  exit 1
fi

cd "$REPO_DIR"

# ── Check for uncommitted changes ─────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
  err "You have uncommitted changes. Commit or stash them first."
  echo ""
  git status --short
  exit 1
fi

# ── Parse arguments ───────────────────────────────────
MODE="interactive"
case "${1:-}" in
  --check) MODE="check" ;;
  --apply) MODE="apply" ;;
  -h|--help)
    echo "Usage: $0 [--check|--apply]"
    echo "  (no args)  Interactive — preview changes, then confirm"
    echo "  --check    Check for updates without applying"
    echo "  --apply    Apply updates without confirmation"
    exit 0
    ;;
  "") ;;
  *)
    err "Unknown option: $1"
    echo "Usage: $0 [--check|--apply]"
    exit 1
    ;;
esac

# ── Set up upstream remote ────────────────────────────
if git remote get-url "$UPSTREAM_REMOTE" &>/dev/null; then
  CURRENT_URL=$(git remote get-url "$UPSTREAM_REMOTE")
  if [ "$CURRENT_URL" != "$UPSTREAM_URL" ]; then
    warn "Upstream remote points to $CURRENT_URL — updating to $UPSTREAM_URL"
    git remote set-url "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  fi
else
  info "Adding upstream remote..."
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  ok "Remote added: $UPSTREAM_REMOTE → $UPSTREAM_URL"
fi

# ── Fetch upstream ────────────────────────────────────
info "Fetching upstream..."
git fetch "$UPSTREAM_REMOTE" 2>&1 | grep -v '^$' || true

LOCAL_HEAD=$(git rev-parse HEAD)
UPSTREAM_HEAD=$(git rev-parse "$UPSTREAM_REMOTE/main" 2>/dev/null || true)

if [ -z "$UPSTREAM_HEAD" ]; then
  err "Could not find upstream/main. Check your network connection."
  exit 1
fi

# ── Check if there are updates ─────────────────────────
# Use merge-base to find common ancestor; if none exists (template repo),
# all upstream commits are "new"
MERGE_BASE=$(git merge-base HEAD "$UPSTREAM_REMOTE/main" 2>/dev/null || echo "")

if [ "$MERGE_BASE" = "$UPSTREAM_HEAD" ]; then
  ok "Already up to date with upstream."
  exit 0
fi

if [ -n "$MERGE_BASE" ]; then
  NEW_COMMITS=$(git rev-list --count "$MERGE_BASE..$UPSTREAM_REMOTE/main")
  DIFF_RANGE="$MERGE_BASE..$UPSTREAM_REMOTE/main"
else
  # No common ancestor (template repo, first sync)
  NEW_COMMITS=$(git rev-list --count "$UPSTREAM_REMOTE/main")
  DIFF_RANGE="$UPSTREAM_REMOTE/main"
fi

info "Found $NEW_COMMITS new commit(s) from upstream"
echo ""

# Show what's coming
echo -e "${BOLD}Upstream changes:${NC}"
if [ -n "$MERGE_BASE" ]; then
  git log --oneline "$MERGE_BASE..$UPSTREAM_REMOTE/main" | while read -r line; do
    echo -e "  ${DIM}$line${NC}"
  done
else
  git log --oneline "$UPSTREAM_REMOTE/main" | head -20 | while read -r line; do
    echo -e "  ${DIM}$line${NC}"
  done
  TOTAL=$(git rev-list --count "$UPSTREAM_REMOTE/main")
  if [ "$TOTAL" -gt 20 ]; then
    echo -e "  ${DIM}... and $((TOTAL - 20)) more${NC}"
  fi
fi
echo ""

# Show changed files categorized
echo -e "${BOLD}Files that will be updated:${NC}"
CORE_COUNT=0
USER_COUNT=0
NEW_COUNT=0

if [ -n "$MERGE_BASE" ]; then
  CHANGED_FILES=$(git diff --name-only "$MERGE_BASE" "$UPSTREAM_REMOTE/main")
else
  CHANGED_FILES=$(git ls-tree -r --name-only "$UPSTREAM_REMOTE/main")
fi

while IFS= read -r file; do
  [ -z "$file" ] && continue
  if [ ! -f "$file" ]; then
    echo -e "  ${GREEN}+ $file${NC} ${DIM}(new)${NC}"
    NEW_COUNT=$((NEW_COUNT + 1))
  elif is_core_file "$file"; then
    echo -e "  ${CYAN}↑ $file${NC} ${DIM}(core — upstream wins)${NC}"
    CORE_COUNT=$((CORE_COUNT + 1))
  else
    echo -e "  ${YELLOW}⊘ $file${NC} ${DIM}(user — yours wins on conflict)${NC}"
    USER_COUNT=$((USER_COUNT + 1))
  fi
done <<< "$CHANGED_FILES"

echo ""
echo -e "  Core updates: ${CYAN}$CORE_COUNT${NC}  |  User files: ${YELLOW}$USER_COUNT${NC}  |  New files: ${GREEN}$NEW_COUNT${NC}"
echo ""

if [ "$MODE" = "check" ]; then
  info "Run ${BOLD}./update.sh${NC} to apply these updates."
  exit 0
fi

# ── Confirm ────────────────────────────────────────────
if [ "$MODE" = "interactive" ]; then
  echo -en "  ${CYAN}?${NC} Apply these updates? ${DIM}[Y/n]${NC}: "
  read -r yn
  case "$yn" in
    [nN]*) info "Aborted."; exit 0 ;;
  esac
fi

# ── Merge ─────────────────────────────────────────────
info "Merging upstream changes..."

# Attempt the merge — allow unrelated histories for template repos
MERGE_OUTPUT=$(git merge "$UPSTREAM_REMOTE/main" \
  --allow-unrelated-histories \
  --no-edit \
  -m "chore: sync with upstream driftarr" 2>&1) || true

# Check if merge completed cleanly
if ! git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
  # No conflicts — clean merge
  ok "Merged cleanly — no conflicts"
  echo ""
  info "Update complete. Review the changes with: git log --oneline -5"
  exit 0
fi

# ── Resolve conflicts ─────────────────────────────────
info "Resolving merge conflicts..."
echo ""

CONFLICTED=$(git diff --name-only --diff-filter=U)
CORE_RESOLVED=0
USER_RESOLVED=0

while IFS= read -r file; do
  [ -z "$file" ] && continue

  if is_core_file "$file"; then
    # Core file — take upstream's version
    git checkout --theirs -- "$file" 2>/dev/null || true
    git add "$file"
    echo -e "  ${CYAN}↑${NC} $file ${DIM}— took upstream${NC}"
    CORE_RESOLVED=$((CORE_RESOLVED + 1))
  else
    # User file — keep local version
    git checkout --ours -- "$file" 2>/dev/null || true
    git add "$file"
    echo -e "  ${YELLOW}●${NC} $file ${DIM}— kept yours${NC}"
    USER_RESOLVED=$((USER_RESOLVED + 1))
  fi
done <<< "$CONFLICTED"

echo ""

# Verify no remaining conflicts
REMAINING=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
  err "Some conflicts could not be auto-resolved:"
  echo "$REMAINING" | while read -r f; do echo -e "  ${RED}$f${NC}"; done
  echo ""
  warn "Resolve these manually, then run: git add <file> && git commit"
  exit 1
fi

# Commit the resolved merge
git commit --no-edit 2>/dev/null || true

echo -e "  Core files updated: ${CYAN}$CORE_RESOLVED${NC}"
echo -e "  User files preserved: ${YELLOW}$USER_RESOLVED${NC}"
echo ""
ok "Update complete."
echo ""
info "Review: ${DIM}git log --oneline -5${NC}"
info "Diff:   ${DIM}git diff HEAD~1${NC}"
echo ""

# ── Remind about deploy ───────────────────────────────
echo -e "${DIM}Push to main to deploy the updated framework to your server.${NC}"
