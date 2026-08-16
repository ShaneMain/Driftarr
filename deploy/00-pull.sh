#!/usr/bin/env bash
# deploy/00-pull.sh — git pull + environment validation
# Sets: BEFORE, AFTER, CHANGED

# ── Environment Validation ────────────────────────────
if [ -f "$REPO_DIR/.env" ]; then
  set -a
  source "$REPO_DIR/.env"
  set +a
fi

validate_env() {
  local missing="" invalid_paths=""

  for var in DOCKER_DIR MEDIA_DIR; do
    val="${!var:-}"
    if [ -z "$val" ]; then
      missing="$missing $var"
    elif ! [[ "$val" =~ ^/ ]]; then
      invalid_paths="$invalid_paths $var='$val'"
    fi
  done

  if [ -d "$REPO_DIR/downloads" ]; then
    val="${DOWNLOADS_DIR:-}"
    if [ -z "$val" ]; then
      warn "DOWNLOADS_DIR not set (downloads stack may fail if used)"
    elif ! [[ "$val" =~ ^/ ]]; then
      invalid_paths="$invalid_paths DOWNLOADS_DIR='$val'"
    fi

    for var in VPN_SERVICE_PROVIDER VPN_TYPE WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES; do
      val="${!var:-}"
      [ -z "$val" ] && warn "VPN config incomplete: $var not set (downloads stack may fail)"
    done
  fi

  if [ -n "$missing" ]; then
    err "Required environment variables not set:$missing"
    err "Create .env file with required values (see .env.example)"
    exit 1
  fi
  if [ -n "$invalid_paths" ]; then
    err "Invalid paths (must be absolute):$invalid_paths"
    exit 1
  fi
}

validate_env

# ── Git Pull ──────────────────────────────────────────
# If we were re-exec'd, BEFORE/AFTER are already set via env vars.
if [ -n "${DEPLOY_REEXEC:-}" ]; then
  BEFORE="${DEPLOY_REEXEC_BEFORE}"
  AFTER="${DEPLOY_REEXEC_AFTER}"
  info "Re-exec'd with updated deploy.sh (${BEFORE:0:7} → ${AFTER:0:7})"
else
  BEFORE=$(git rev-parse HEAD)

  # ── Dirty worktree recovery ─────────────────────────
  # Manual edits or interrupted exports on the server can block `git pull
  # --ff-only` ("local/untracked changes would be overwritten"), wedging every
  # deploy until a human intervenes. Only when the pull is actually blocked:
  # stash everything dirty (recoverable via `git stash list`) and retry once.
  # Untracked runtime files that don't collide with incoming changes are
  # deliberately left alone.
  info "Pulling latest changes..."
  if ! git pull --ff-only origin "$BRANCH"; then
    warn "Pull blocked by local changes — stashing and retrying:"
    git status --porcelain | while read -r line; do warn "  $line"; done
    if ! git stash push --include-untracked -m "deploy-autostash $(date -Is)" >/dev/null; then
      err "Could not stash local changes — resolve manually on the server"
      exit 1
    fi
    warn "Stashed (recover with: git stash list / git stash pop)"
    if ! git pull --ff-only origin "$BRANCH"; then
      # Divergence, not dirty tree: local has commits origin lacks (classic
      # cause: an auto-export commit whose push was rejected). Rebase local
      # commits onto the remote tip so deploys self-heal; a single transient
      # push failure must never wedge every future deploy. Conflicts are
      # not auto-resolvable — abort and fail loudly for a human.
      warn "Diverged from origin/$BRANCH — rebasing local commits..."
      git fetch origin "$BRANCH"
      if git rebase "FETCH_HEAD"; then
        warn "Rebased onto origin/$BRANCH ($(git rev-parse --short HEAD))"
      else
        git rebase --abort 2>/dev/null
        err "Rebase onto origin/$BRANCH failed — conflicts need a human"
        err "Inspect on the server: git log --oneline origin/$BRANCH..HEAD && git rebase origin/$BRANCH"
        exit 1
      fi
    fi
  fi
  AFTER=$(git rev-parse HEAD)

  if [ "$BEFORE" = "$AFTER" ]; then
    if ! git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      info "Already up to date and only one commit exists — nothing to deploy."
      exit 0
    fi
    BEFORE=$(git rev-parse HEAD~1)
    info "Already up to date — using HEAD~1..HEAD (${BEFORE:0:7}..${AFTER:0:7})"
  fi

  # If deploy.sh itself changed, re-exec the updated version.
  # Module scripts (deploy/*) are sourced fresh from disk after pull,
  # so they don't need a re-exec — only the entrypoint does.
  if git diff --name-only "$BEFORE" "$AFTER" | grep -qx 'deploy.sh'; then
    info "deploy.sh updated — re-executing with new version..."
    export DEPLOY_REEXEC=1 DEPLOY_REEXEC_BEFORE="$BEFORE" DEPLOY_REEXEC_AFTER="$AFTER"
    exec "$REPO_DIR/deploy.sh"
  fi
fi

info "Deploying ${BEFORE:0:7} → ${AFTER:0:7}"
log "Commit: $(git log --oneline -1 "$AFTER")"

# Skip deploy for auto-export commits (configs are already live on services)
COMMIT_MSG=$(git log --format=%s -1 "$AFTER")
if echo "$COMMIT_MSG" | grep -q '^chore(configs): auto-export'; then
  info "Auto-export commit detected — configs already live, skipping deploy."
  exit 0
fi
sep

CHANGED=$(git diff --name-only "$BEFORE" "$AFTER")
