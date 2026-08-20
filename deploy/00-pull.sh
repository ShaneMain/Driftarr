#!/usr/bin/env bash
# deploy/00-pull.sh — git pull + environment validation
# Sets: BEFORE, AFTER, CHANGED

# ── Environment Validation ────────────────────────────
# Read .env the way Compose does — NOT by sourcing it as shell. `source`
# word-splits, glob-expands and evaluates `$`, backticks and quotes, so a
# password like p@ss$word became p@ss (and, being exported, overrode compose's
# own correct parsing), and `Q=a b` ran the command `b`.
# Values are exported so compose and the deploy hooks see them; since an
# exported variable beats .env inside Compose, the parser follows Compose's
# semantics for the common cases (verified against `docker compose config`):
#   KEY= value   → surrounding whitespace trimmed
#   KEY=v # c    → inline " #..." comment stripped from unquoted values
#   KEY="v"      → double quotes removed, \" and \\ unescaped, ${VAR} expanded
#   KEY='v'      → single quotes removed, nothing expanded
#   ${VAR} ${VAR:-def} ${VAR-def} $VAR $$ → expanded against keys loaded so far
#                  and the existing environment (no command substitution, no
#                  other shell evaluation)
_env_interpolate() {
  local in="$1" out="" c name def rest
  while [ -n "$in" ]; do
    c="${in:0:1}"
    if [ "$c" != '$' ]; then
      out+="$c"; in="${in:1}"; continue
    fi
    rest="${in:1}"
    if [ "${rest:0:1}" = '$' ]; then                  # $$ → literal $
      out+='$'; in="${rest:1}"
    elif [[ "$rest" =~ ^\{([A-Za-z_][A-Za-z0-9_]*)(:?-([^}]*))?\} ]]; then
      name="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[3]}"
      if [ -n "${!name:-}" ] || { [ "${BASH_REMATCH[2]:0:1}" != ':' ] && [ -n "${!name+x}" ]; }; then
        out+="${!name}"
      else
        out+="$def"
      fi
      in="${rest:${#BASH_REMATCH[0]}}"
    elif [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then
      name="${BASH_REMATCH[1]}"
      out+="${!name:-}"
      in="${rest:${#name}}"
    else
      out+='$'; in="$rest"
    fi
  done
  printf '%s' "$out"
}

load_env_file() {
  local file="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"            # ltrim
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    val="${line#*=}"
    [ "$key" = "$line" ] && continue                 # no '='
    key="${key%"${key##*[![:space:]]}"}"             # rtrim key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val#"${val%%[![:space:]]*}"}"             # ltrim value
    case "$val" in
      \"*)
        val="${val:1}"
        if [[ "$val" =~ ^((\\.|[^\"\\])*)\" ]]; then val="${BASH_REMATCH[1]}"; fi
        val="${val//\\\"/\"}"; val="${val//\\\\/\\}"
        val=$(_env_interpolate "$val")
        ;;
      \'*)
        val="${val:1}"; val="${val%%\'*}"
        ;;
      *)
        val="${val%%[[:space:]]#*}"                    # strip " # comment"
        val="${val%"${val##*[![:space:]]}"}"           # rtrim
        val=$(_env_interpolate "$val")
        ;;
    esac
    export "$key=$val"
  done < "$file"
}

if [ -f "$REPO_DIR/.env" ]; then
  load_env_file "$REPO_DIR/.env"
fi

validate_env() {
  local missing="" invalid_paths="" var val

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

  # ── Resume from the last fully-successful deploy ───
  # HEAD is "what was pulled", not "what is running". If the previous run had
  # a failed/rolled-back stack, 90-summary did not advance .last-deployed, so
  # diffing from it makes the next run re-cover that range and retry the stack
  # (drift detection can't: it excludes docker-compose.yml). Only trusted when
  # it is an ancestor of HEAD (history rewrite / fresh clone → fall back).
  if _last=$(cat "$REPO_DIR/.last-deployed" 2>/dev/null) && [ -n "$_last" ] \
     && git merge-base --is-ancestor "$_last" HEAD 2>/dev/null; then
    if [ "$_last" != "$BEFORE" ]; then
      info "Resuming from last successful deploy ${_last:0:7} (HEAD was ${BEFORE:0:7})"
    fi
    BEFORE="$_last"
  fi
  unset _last

  # ── Fetch, then fast-forward ────────────────────────
  # Fetch is separated from the merge so a network/auth failure fails HERE,
  # cleanly, and is never mistaken for a dirty worktree (which used to stash
  # every untracked file away and then die without popping it).
  info "Pulling latest changes..."
  if ! git fetch origin "$BRANCH"; then
    err "git fetch origin/$BRANCH failed — network/auth problem, worktree untouched"
    exit 1
  fi

  # ── Dirty worktree recovery ─────────────────────────
  # Manual edits or interrupted exports on the server can block the
  # fast-forward ("local/untracked changes would be overwritten"), wedging
  # every deploy until a human intervenes. Only when git reports exactly that:
  # stash everything dirty (recoverable via `git stash list`) and retry once.
  # If the retry still fails the stash is popped back so nothing is lost.
  # Untracked runtime files that don't collide with incoming changes are
  # deliberately left alone.
  _merged=false _stashed=false
  if _merge_out=$(git merge --ff-only FETCH_HEAD 2>&1); then
    _merged=true
  elif grep -q 'would be overwritten' <<<"$_merge_out"; then
    warn "Pull blocked by local changes — stashing and retrying:"
    git status --porcelain | while read -r line; do warn "  $line"; done
    if ! git stash push --include-untracked -m "deploy-autostash $(date -Is)" >/dev/null; then
      err "Could not stash local changes — resolve manually on the server"
      exit 1
    fi
    _stashed=true
    warn "Stashed (recover with: git stash list / git stash pop)"
    if _merge_out=$(git merge --ff-only FETCH_HEAD 2>&1); then
      _merged=true
    elif grep -q 'would be overwritten' <<<"$_merge_out"; then
      git stash pop >/dev/null 2>&1 || warn "stash pop failed — see: git stash list"
      err "Fast-forward still blocked after stashing: $_merge_out"
      exit 1
    fi
  fi
  if [ "$_merged" = false ]; then
    # Divergence, not dirty tree: local has commits origin lacks (classic
    # cause: an auto-export commit whose push was rejected). Rebase local
    # commits onto the remote tip so deploys self-heal; a single transient
    # push failure must never wedge every future deploy. Conflicts are
    # not auto-resolvable — abort and fail loudly for a human.
    # --autostash: an uncommitted tracked change that does NOT collide with the
    # incoming files is not stashed above, yet would make plain `git rebase`
    # refuse ("You have unstaged changes") and wedge every deploy. Autostash
    # re-applies it after the rebase (or after an abort).
    warn "Diverged from origin/$BRANCH — rebasing local commits..."
    if git rebase --autostash FETCH_HEAD; then
      warn "Rebased onto origin/$BRANCH ($(git rev-parse --short HEAD))"
    else
      git rebase --abort 2>/dev/null || true
      [ "$_stashed" = true ] && { git stash pop >/dev/null 2>&1 || warn "stash pop failed — see: git stash list"; }
      err "Rebase onto origin/$BRANCH failed — conflicts need a human"
      err "Inspect on the server: git log --oneline origin/$BRANCH..HEAD && git rebase origin/$BRANCH"
      exit 1
    fi
  fi
  unset _merged _stashed _merge_out
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

CHANGED=$(git diff --name-only "$BEFORE" "$AFTER")

# Skip deploy when the whole range only touched configs/data/ (auto-export
# commits: the configs are already live on the services). Decided on the DIFF,
# not the tip commit's subject — an export cron commit landing on top of a
# user's push used to hide the user's compose change from the deploy forever.
if [ -n "$CHANGED" ] && ! grep -qv '^configs/data/' <<<"$CHANGED"; then
  info "Only configs/data/ changed (auto-export) — configs already live, skipping deploy."
  # Nothing to deploy means HEAD is as-deployed; record it so the next run's
  # resume range (see .last-deployed above) doesn't keep re-including this.
  printf '%s\n' "$AFTER" > "$REPO_DIR/.last-deployed" 2>/dev/null || true
  exit 0
fi
sep
