#!/usr/bin/env bash
set -euo pipefail

# ── driftarr setup wizard ─────────────────────────────
# Complete guided setup and teardown for automated Docker Compose deploys.
#
# Usage:
#   ./setup.sh           # Interactive — choose install or uninstall
#   ./setup.sh install    # Skip the menu, go straight to install
#   ./setup.sh uninstall  # Skip the menu, go straight to uninstall
#
# Quick start (on a fresh server):
#   bash <(curl -fsSL https://raw.githubusercontent.com/ShaneMain/Driftarr/main/setup.sh)

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

CURRENT_USER="$(whoami)"

info()  { echo -e "${CYAN}▶${NC} $*"; }
ok()    { echo -e "${GREEN}  ✅${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠️${NC}  $*"; }
err()   { echo -e "${RED}  ❌${NC} $*"; }
step()  { echo ""; echo -e "${BOLD}━━ Step $1: $2 ━━${NC}"; }
prompt() {
  local var="$1" msg="$2" default="${3:-}"
  if [ -n "$default" ]; then
    echo -en "  ${CYAN}?${NC} ${msg} ${DIM}[${default}]${NC}: "
    read -r input
    printf -v "$var" '%s' "${input:-$default}"
  else
    echo -en "  ${CYAN}?${NC} ${msg}: "
    read -r input
    printf -v "$var" '%s' "$input"
  fi
}
prompt_secret() {
  local var="$1" msg="$2"
  echo -en "  ${CYAN}?${NC} ${msg} ${DIM}(hidden)${NC}: "
  read -rs input
  echo ""
  printf -v "$var" '%s' "$input"
}
validate_path() {
  local path="$1" label="$2"
  if [[ "$path" =~ [[:space:]] ]]; then
    err "$label cannot contain spaces: '$path'"
    return 1
  fi
  if [[ ! "$path" =~ ^/ ]]; then
    err "$label must be an absolute path: '$path'"
    return 1
  fi
  if [[ "$path" =~ \.\. ]]; then
    err "$label cannot contain '..': '$path'"
    return 1
  fi
  return 0
}
validate_github_repo() {
  local repo="$1"
  if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    err "Invalid GitHub repo format: '$repo' (expected: owner/repo)"
    return 1
  fi
  return 0
}
validate_timezone() {
  local tz="$1"
  if [[ ! "$tz" =~ ^[A-Za-z_]+/[A-Za-z_]+$ ]]; then
    err "Invalid timezone format: '$tz' (expected: Region/City, e.g. America/New_York)"
    return 1
  fi
  return 0
}
validate_nonempty() {
  local val="$1" label="$2"
  if [ -z "$val" ]; then
    err "$label cannot be empty"
    return 1
  fi
  return 0
}
confirm() {
  echo -en "  ${CYAN}?${NC} $1 ${DIM}[Y/n]${NC}: "
  read -r yn
  case "$yn" in [nN]*) return 1 ;; *) return 0 ;; esac
}
confirm_no() {
  echo -en "  ${CYAN}?${NC} $1 ${DIM}[y/N]${NC}: "
  read -r yn
  case "$yn" in [yY]*) return 0 ;; *) return 1 ;; esac
}
wait_for_user() {
  echo ""
  echo -en "  ${DIM}Press Enter when done...${NC}"
  read -r
}

# ══════════════════════════════════════════════════════
# Uninstall
# ══════════════════════════════════════════════════════
do_uninstall() {
  # Ensure we're in a valid directory — the user may be running this from
  # inside the repo dir that's about to be deleted
  cd "$HOME"

  echo ""
  echo -e "${BOLD}  Driftarr — uninstall${NC}"
  echo -e "${DIM}  This removes the deploy pipeline and optionally tears down stacks.${NC}"
  echo ""

  # Find the repo
  while true; do
    prompt REPO_DIR "Where is the repo on this server?" "/home/${CURRENT_USER}/docker-stacks"
    validate_path "$REPO_DIR" "Repo directory" && break
  done

  # ── Docker stacks ────────────────────────────────────
  step 1 "Docker stacks"

  if [ -f "$REPO_DIR/docker-compose.yml" ]; then
    if confirm "Stop and remove all Docker stacks?"; then
      info "Stopping stacks..."
      docker compose -f "$REPO_DIR/docker-compose.yml" down 2>&1 || true

      # Also stop individual stacks that might not be in root compose
      for dir in "$REPO_DIR"/*/; do
        if [ -f "$dir/docker-compose.yml" ]; then
          docker compose -f "$dir/docker-compose.yml" down 2>&1 || true
        fi
      done
      ok "All stacks stopped and removed"

      # Container data directories
      echo ""
      if [ -f "$REPO_DIR/.env" ]; then
        DOCKER_DIR=$(grep '^DOCKER_DIR=' "$REPO_DIR/.env" 2>/dev/null | cut -d= -f2 || true)
      fi
      if [ -n "${DOCKER_DIR:-}" ] && [ -d "$DOCKER_DIR" ]; then
        warn "Container data directory: ${BOLD}${DOCKER_DIR}${NC}"
        echo -e "  ${DIM}This contains all persistent data (configs, databases, etc.)${NC}"
        echo -e "  ${RED}  This is destructive and cannot be undone.${NC}"
        if confirm_no "Delete container data directory ($DOCKER_DIR)?"; then
          if confirm_no "Are you sure? This deletes ALL container configs and data"; then
            sudo rm -rf "$DOCKER_DIR"
            ok "Container data deleted: $DOCKER_DIR"
          else
            info "Kept $DOCKER_DIR"
          fi
        else
          info "Kept $DOCKER_DIR"
        fi
      fi
    else
      info "Stacks left running"
    fi
  else
    info "No docker-compose.yml found — nothing to stop"
  fi

  # ── Config export cron ───────────────────────────────
  step 2 "Config export cron"

  if crontab -l 2>/dev/null | grep -qF "run-export.sh"; then
    if confirm "Remove config export cron job?"; then
      crontab -l 2>/dev/null | grep -vF "run-export.sh" | crontab -
      ok "Cron job removed"
    fi
  else
    ok "No config export cron found"
  fi

  # ── Deploy user ──────────────────────────────────────
  step 3 "Deploy user"

  SSHD_CONF="/etc/ssh/sshd_config.d/60-deploy.conf"
  SUDOERS_FILE="/etc/sudoers.d/deploy"

  if [ -f "$SSHD_CONF" ]; then
    if confirm "Remove sshd deploy config ($SSHD_CONF)?"; then
      sudo rm -f "$SSHD_CONF"
      sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null || true
      ok "sshd config removed and reloaded"
    fi
  fi

  if [ -f "$SUDOERS_FILE" ]; then
    if confirm "Remove deploy sudoers ($SUDOERS_FILE)?"; then
      sudo rm -f "$SUDOERS_FILE"
      ok "Sudoers removed"
    fi
  fi

  if id deploy &>/dev/null; then
    if confirm "Delete deploy system user?"; then
      sudo userdel -r deploy 2>/dev/null || sudo userdel deploy 2>/dev/null || true
      ok "deploy user deleted"
    fi
  fi

  # ── SSH keys ─────────────────────────────────────────
  step 4 "SSH keys"

  for key in "$HOME/.ssh/driftarr_deploy" "$HOME/.ssh/driftarr_git"; do
    if [ -f "$key" ]; then
      if confirm "Delete SSH key: $key?"; then
        rm -f "$key" "${key}.pub"
        ok "Deleted $key"
      fi
    fi
  done

  # Clean SSH config entry
  SSH_CONFIG="$HOME/.ssh/config"
  if [ -f "$SSH_CONFIG" ] && grep -q "driftarr-git" "$SSH_CONFIG"; then
    if confirm "Remove driftarr-git entry from SSH config?"; then
      sed -i '/# driftarr git access/,/IdentitiesOnly yes/d' "$SSH_CONFIG"
      # Clean up any trailing blank lines left behind
      sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$SSH_CONFIG"
      ok "SSH config cleaned"
    fi
  fi

  # ── Firewall rules ─────────────────────────────────
  step 5 "Firewall rules"

  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw status 2>/dev/null | grep -q "tailscale0.*22"; then
      if confirm "Remove UFW rule allowing SSH on tailscale0?"; then
        sudo ufw delete allow in on tailscale0 to any port 22 proto tcp 2>/dev/null || true
        ok "UFW rule removed"
      fi
    else
      ok "No driftarr UFW rules found"
    fi
  elif command -v firewall-cmd &>/dev/null; then
    TS_ZONE=$(firewall-cmd --get-zone-of-interface=tailscale0 2>/dev/null || true)
    if [ -n "$TS_ZONE" ] && firewall-cmd --zone="$TS_ZONE" --query-service=ssh 2>/dev/null; then
      if confirm "Remove firewalld SSH rule from zone '$TS_ZONE'?"; then
        sudo firewall-cmd --zone="$TS_ZONE" --remove-service=ssh --permanent
        sudo firewall-cmd --reload
        ok "firewalld rule removed"
      fi
    fi
  fi

  # ── Repo directory ──────────────────────────────────
  step 6 "Repository"

  if [ -d "$REPO_DIR" ]; then
    warn "Repo directory: ${BOLD}${REPO_DIR}${NC}"
    echo -e "  ${DIM}Your .env, configs, and git history are here.${NC}"
    if confirm_no "Delete the repo directory?"; then
      rm -rf "$REPO_DIR"
      ok "Repo deleted: $REPO_DIR"
    else
      info "Kept $REPO_DIR"
    fi
  fi

  # ── Done ─────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}━━ Uninstall complete ━━${NC}"
  echo ""
  ok "Deploy pipeline removed."
  echo ""
  info "What's still installed (system packages you may want to keep):"
  echo -e "  • Docker, Git, Python 3, Tailscale"
  echo -e "  ${DIM}These are general-purpose tools — remove them manually if needed.${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════
# Install
# ══════════════════════════════════════════════════════
do_install() {
  # Ensure we're in a valid directory — if the user ran uninstall first and
  # deleted the repo dir, the shell's cwd may no longer exist, which causes
  # git (and other tools) to fail with "Unable to read current working directory"
  cd "$HOME"

  echo ""
  echo -e "${BOLD}  Driftarr — install${NC}"
  echo -e "${DIM}  Automated Docker Compose deploys via GitHub Actions + Tailscale${NC}"
  echo ""
  echo -e "${DIM}  This wizard walks you through the complete server setup.${NC}"
  echo -e "${DIM}  Safe to re-run — existing config is detected and skipped.${NC}"
  echo ""

  # ── Prerequisites ────────────────────────────────────
  step 1 "Checking prerequisites"

  MISSING=""
  for cmd in docker git python3 crontab; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd — $(command -v "$cmd")"
    else
      err "$cmd not found"
      MISSING="$MISSING $cmd"
    fi
  done

  if docker compose version &>/dev/null; then
    ok "docker compose v2 — $(docker compose version --short)"
  else
    err "docker compose v2 not found (need 'docker compose', not 'docker-compose')"
    MISSING="$MISSING docker-compose-v2"
  fi

  TS_IP=""
  if command -v tailscale &>/dev/null; then
    ok "tailscale — $(command -v tailscale)"
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
      ok "Tailscale connected — $TS_IP"
    else
      warn "Tailscale installed but not connected"
      info "Run: sudo tailscale up"
    fi
  else
    err "tailscale not found"
    MISSING="$MISSING tailscale"
  fi

  if [ -n "$MISSING" ]; then
    echo ""
    err "Missing:$MISSING"
    info "Install the missing tools and re-run this script."
    exit 1
  fi

  # Ensure Docker daemon is enabled and running
  if ! systemctl is-active --quiet docker 2>/dev/null; then
    warn "Docker daemon is not running"
    if confirm "Enable and start Docker now?"; then
      sudo systemctl enable --now docker
      ok "Docker daemon started and enabled"
    else
      err "Docker must be running to continue"
      exit 1
    fi
  else
    ok "Docker daemon running"
  fi

  # Ensure current user is in the docker group
  if ! groups "$CURRENT_USER" 2>/dev/null | grep -qw docker; then
    warn "$CURRENT_USER is not in the docker group"
    if confirm "Add $CURRENT_USER to the docker group?"; then
      sudo usermod -aG docker "$CURRENT_USER"
      ok "$CURRENT_USER added to docker group"
      warn "Group change requires a new login session to take effect."
      info "Log out and back in, then re-run: ./setup.sh install"
      exit 0
    else
      warn "Docker commands may fail without docker group membership"
    fi
  fi

  # Ensure Tailscale daemon is enabled and running
  if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    warn "Tailscale daemon is not running"
    if confirm "Enable and start Tailscale now?"; then
      sudo systemctl enable --now tailscaled
      ok "Tailscale daemon started and enabled"
      # Re-check connection
      info "You may need to authenticate: sudo tailscale up"
      TS_IP=$(tailscale ip -4 2>/dev/null || true)
    else
      err "Tailscale must be running to continue"
      exit 1
    fi
  else
    ok "Tailscale daemon running"
  fi

  # Ensure sshd is enabled and running (GitHub Actions SSHes into this server)
  if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
    warn "SSH server (sshd) is not running"
    echo -e "  ${DIM}GitHub Actions needs to SSH into this server to deploy.${NC}"
    if confirm "Enable and start sshd now?"; then
      if systemctl list-unit-files sshd.service &>/dev/null; then
        sudo systemctl enable --now sshd
      else
        sudo systemctl enable --now ssh
      fi
      ok "sshd started and enabled"
    else
      err "sshd must be running for deploys to work"
      exit 1
    fi
  else
    ok "sshd running"
  fi

  # Ensure firewall allows SSH on the Tailscale interface
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw status 2>/dev/null | grep -q "tailscale0.*22"; then
      warn "UFW is active but no rule allows SSH on the Tailscale interface"
      echo -e "  ${DIM}Without this, GitHub Actions can't reach sshd through Tailscale.${NC}"
      if confirm "Allow SSH on tailscale0 interface?"; then
        sudo ufw allow in on tailscale0 to any port 22 proto tcp
        ok "UFW rule added: allow SSH on tailscale0"
      else
        warn "Deploy pipeline may fail — SSH blocked on Tailscale interface"
      fi
    else
      ok "UFW allows SSH on tailscale0"
    fi
  elif command -v firewall-cmd &>/dev/null; then
    TS_ZONE=$(firewall-cmd --get-zone-of-interface=tailscale0 2>/dev/null || true)
    if [ -n "$TS_ZONE" ]; then
      if ! firewall-cmd --zone="$TS_ZONE" --query-service=ssh 2>/dev/null; then
        warn "firewalld: SSH not allowed in zone '$TS_ZONE' (tailscale0 interface)"
        if confirm "Allow SSH in the '$TS_ZONE' zone?"; then
          sudo firewall-cmd --zone="$TS_ZONE" --add-service=ssh --permanent
          sudo firewall-cmd --reload
          ok "firewalld: SSH allowed in zone $TS_ZONE"
        else
          warn "Deploy pipeline may fail — SSH blocked on Tailscale interface"
        fi
      else
        ok "firewalld allows SSH on tailscale0 (zone: $TS_ZONE)"
      fi
    else
      ok "firewalld: tailscale0 not in a restricted zone"
    fi
  fi

  ok "All prerequisites met"

  # ── Repository ───────────────────────────────────────
  step 2 "Repository"

  while true; do
    prompt REPO_DIR "Where should the repo live on this server?" "/home/${CURRENT_USER}/docker-stacks"
    validate_path "$REPO_DIR" "Repo directory" && break
  done

  GIT_KEY="$HOME/.ssh/driftarr_git"

  if [ -d "$REPO_DIR/.git" ]; then
    ok "Repo already cloned at $REPO_DIR"

    # Check if the remote points at the expected repo
    CURRENT_REMOTE=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)

    echo ""
    info "First, confirm which GitHub repo this server should deploy from."
    echo -e "    ${DIM}Current remote: ${CURRENT_REMOTE}${NC}"
    prompt GITHUB_REPO "Your GitHub repo (e.g. yourname/your-repo or full URL)" ""
    if [ -n "$GITHUB_REPO" ]; then
      GITHUB_REPO=$(echo "$GITHUB_REPO" | sed -E 's#^https?://github\.com/##; s#\.git$##; s#/settings/.*##; s#/$##')
      if ! validate_github_repo "$GITHUB_REPO"; then
        warn "Skipping remote check — fix the repo name and re-run"
        GITHUB_REPO=""
      else
        EXPECTED_URL="git@github.com-driftarr:${GITHUB_REPO}.git"

        if [ "$CURRENT_REMOTE" != "$EXPECTED_URL" ]; then
          warn "Remote mismatch detected"
          echo -e "    Current:  ${RED}${CURRENT_REMOTE}${NC}"
          echo -e "    Expected: ${GREEN}${EXPECTED_URL}${NC}"
          if confirm "Update the remote to ${EXPECTED_URL}?"; then
            git -C "$REPO_DIR" remote set-url origin "$EXPECTED_URL"
            ok "Remote updated to $EXPECTED_URL"
          else
            warn "Remote left unchanged — deploys will pull from the current remote"
          fi
        else
          ok "Remote already correct: $EXPECTED_URL"
        fi
      fi
    else
      info "Skipped remote check"
    fi
  else
    echo ""
    info "First, create your own repo from the template on GitHub:"
    echo -e "    ${CYAN}https://github.com/ShaneMain/Driftarr${NC}"
    echo -e "    Click ${BOLD}\"Use this template\" → \"Create a new repository\"${NC}"
    echo -e "    ${BOLD}Make it private${NC} — your Docker configs and server paths don't belong in a public repo."
    wait_for_user

    while true; do
      prompt GITHUB_REPO "Your GitHub repo (e.g. yourname/your-repo or full URL)"
      # Normalize: strip https://github.com/, .git, trailing paths, slashes
      GITHUB_REPO=$(echo "$GITHUB_REPO" | sed -E 's#^https?://github\.com/##; s#\.git$##; s#/settings/.*##; s#/$##')
      validate_nonempty "$GITHUB_REPO" "GitHub repo" && validate_github_repo "$GITHUB_REPO" && break
    done
    CLONE_URL="git@github.com-driftarr:${GITHUB_REPO}.git"

    # SSH key for git operations
    if [ -f "$GIT_KEY" ]; then
      ok "Git SSH key already exists: $GIT_KEY"
    else
      info "Generating SSH key for git operations..."
      ssh-keygen -t ed25519 -C "driftarr-git-$(hostname)" -f "$GIT_KEY" -N ""
      ok "Key generated: $GIT_KEY"
    fi

    echo ""
    info "Add this as a deploy key on your repo:"
    echo -e "    ${CYAN}https://github.com/${GITHUB_REPO}/settings/keys${NC}"
    echo ""
    echo -e "    Title: ${DIM}$(hostname) server${NC}"
    echo -e "    Check ${BOLD}\"Allow write access\"${NC} (needed for config export)"
    echo ""
    echo -e "    ${BOLD}Public key:${NC}"
    echo ""
    cat "${GIT_KEY}.pub"
    echo ""
    wait_for_user

    # SSH config alias
    SSH_CONFIG="$HOME/.ssh/config"
    if grep -q "driftarr-git" "$SSH_CONFIG" 2>/dev/null; then
      ok "SSH config already has driftarr-git entry"
    else
      mkdir -p "$HOME/.ssh"
      cat >> "$SSH_CONFIG" << SSHEOF

# driftarr git access
Host github.com-driftarr
  HostName github.com
  User git
  IdentityFile ${GIT_KEY}
  IdentitiesOnly yes
SSHEOF
      chmod 600 "$SSH_CONFIG"
      ok "SSH config updated — github.com-driftarr alias added"
    fi

    info "Cloning ${GITHUB_REPO} to ${REPO_DIR}..."
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "$CLONE_URL" "$REPO_DIR"
    git -C "$REPO_DIR" remote set-url origin "$CLONE_URL"
    ok "Cloned to $REPO_DIR"
  fi

  # ── Environment variables ──────────────────────────
  step 3 "Environment configuration"

  if [ -f "$REPO_DIR/.env" ]; then
    ok ".env already exists at $REPO_DIR/.env"
    if ! confirm "Regenerate it?"; then
      SKIP_ENV=true
    else
      SKIP_ENV=false
    fi
  else
    SKIP_ENV=false
  fi

  if [ "$SKIP_ENV" = false ]; then
    echo -e "  ${DIM}Press Enter to accept defaults. Leave secrets blank to fill in later.${NC}"
    echo ""

    prompt ENV_TZ "Timezone" "America/New_York"
    if ! validate_timezone "$ENV_TZ"; then
      warn "Using value anyway — double-check it's a valid tz database entry"
    fi

    while true; do
      prompt ENV_MEDIA_DIR "Media directory (movies, tv, etc.)" "/data/media"
      validate_path "$ENV_MEDIA_DIR" "Media directory" && break
    done
    while true; do
      prompt ENV_DOCKER_DIR "Docker config directory (persistent volumes)" "/opt/docker"
      validate_path "$ENV_DOCKER_DIR" "Docker config directory" && break
    done
    while true; do
      prompt ENV_DOWNLOADS_DIR "Downloads directory" "/data/downloads"
      validate_path "$ENV_DOWNLOADS_DIR" "Downloads directory" && break
    done

    echo ""
    info "VPN (for Gluetun — downloads stack)"
    echo -e "  ${DIM}https://github.com/qdm12/gluetun-wiki for provider setup${NC}"
    prompt ENV_VPN_PROVIDER "VPN provider" "mullvad"
    prompt ENV_VPN_TYPE "VPN type" "wireguard"
    prompt_secret ENV_WG_KEY "WireGuard private key (blank = set later)"
    prompt ENV_WG_ADDR "WireGuard addresses (blank = set later)" ""

    echo ""
    info "Network (dns + dashboard stacks)"
    prompt ENV_DNS_SERVER_IP "LAN IP the DNS server (AdGuard) binds to" ""
    prompt ENV_DASHBOARD_HOST "Dashboard host (IP or hostname)" ""

    # Start from the documented template so no required variable is ever
    # silently missing from the generated .env, then fill in the prompted
    # values. (A hand-written subset used to omit e.g. DNS_SERVER_IP, which the
    # always-included dns stack hard-fails without.)
    _set_env() {
      local key="$1" val="$2" esc
      esc=$(printf '%s' "$val" | sed 's/[&|\\]/\\&/g')
      if grep -qE "^${key}=" "$REPO_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=${esc}|" "$REPO_DIR/.env"
      else
        printf '%s=%s\n' "$key" "$val" >> "$REPO_DIR/.env"
      fi
    }
    cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
    _set_env TZ "$ENV_TZ"
    _set_env MEDIA_DIR "$ENV_MEDIA_DIR"
    _set_env DOCKER_DIR "$ENV_DOCKER_DIR"
    _set_env DOWNLOADS_DIR "$ENV_DOWNLOADS_DIR"
    _set_env VPN_SERVICE_PROVIDER "$ENV_VPN_PROVIDER"
    _set_env VPN_TYPE "$ENV_VPN_TYPE"
    _set_env WIREGUARD_PRIVATE_KEY "$ENV_WG_KEY"
    _set_env WIREGUARD_ADDRESSES "$ENV_WG_ADDR"
    _set_env DNS_SERVER_IP "$ENV_DNS_SERVER_IP"
    _set_env DASHBOARD_HOST "$ENV_DASHBOARD_HOST"

    chmod 600 "$REPO_DIR/.env"
    ok ".env created (mode 600)"
  fi

  # Symlink .env into each stack
  info "Symlinking .env into stack directories..."
  for dir in "$REPO_DIR"/*/; do
    if [ -f "$dir/docker-compose.yml" ]; then
      ln -sf "$REPO_DIR/.env" "$dir/.env"
      ok "$(basename "$dir")/"
    fi
  done

  # ── Deploy user ──────────────────────────────────────
  step 4 "Deploy user (for CI/CD)"

  info "This creates a locked-down 'deploy' user that GitHub Actions SSHes into."
  info "Three security layers restrict it to only running deploy.sh."
  echo ""

  # Create user
  if id deploy &>/dev/null; then
    ok "deploy user already exists"
  else
    if confirm "Create 'deploy' system user?"; then
      sudo useradd -r -s /bin/bash -m deploy
      ok "deploy user created"
    else
      warn "Skipped — create it manually before deploys will work"
    fi
  fi

  # Generate deploy SSH key
  DEPLOY_KEY="$HOME/.ssh/driftarr_deploy"
  if [ -f "$DEPLOY_KEY" ]; then
    ok "Deploy SSH key already exists: $DEPLOY_KEY"
  else
    info "Generating SSH key for GitHub Actions → server..."
    ssh-keygen -t ed25519 -C "github-actions-deploy" -f "$DEPLOY_KEY" -N ""
    ok "Key generated: $DEPLOY_KEY"
  fi

  # Install public key into deploy user's authorized_keys
  if [ -d /home/deploy ]; then
    AUTHKEYS="/home/deploy/.ssh/authorized_keys"
    DEPLOY_PUBKEY=$(cat "${DEPLOY_KEY}.pub")

    if [ -f "$AUTHKEYS" ] && grep -qF "github-actions-deploy" "$AUTHKEYS"; then
      ok "authorized_keys already configured"
    else
      sudo mkdir -p /home/deploy/.ssh
      echo "command=\"sudo -u ${CURRENT_USER} ${REPO_DIR}/deploy.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${DEPLOY_PUBKEY}" | sudo tee "$AUTHKEYS" > /dev/null
      sudo chown -R deploy:deploy /home/deploy/.ssh
      sudo chmod 700 /home/deploy/.ssh
      sudo chmod 600 "$AUTHKEYS"
      ok "authorized_keys configured with command restriction"
    fi
  fi

  # Sudoers
  SUDOERS_FILE="/etc/sudoers.d/deploy"
  if [ -f "$SUDOERS_FILE" ]; then
    ok "sudoers already configured"
  else
    if confirm "Configure sudoers (deploy → ${CURRENT_USER} for deploy.sh only)?"; then
      echo "deploy ALL=(${CURRENT_USER}) NOPASSWD: ${REPO_DIR}/deploy.sh" | sudo tee "$SUDOERS_FILE" > /dev/null
      sudo chmod 440 "$SUDOERS_FILE"
      ok "sudoers configured"
    fi
  fi

  # sshd lockdown
  SSHD_CONF="/etc/ssh/sshd_config.d/60-deploy.conf"
  if [ -f "$SSHD_CONF" ]; then
    ok "sshd deploy config already exists"
  else
    if confirm "Lock down SSH for deploy user (ForceCommand + no forwarding)?"; then
      sudo tee "$SSHD_CONF" > /dev/null << SSHDEOF
Match User deploy
    ForceCommand sudo -u ${CURRENT_USER} ${REPO_DIR}/deploy.sh
    PermitTTY no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
SSHDEOF
      if sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null; then
        ok "sshd config written and reloaded"
      else
        ok "sshd config written"
        warn "Could not reload sshd — run: sudo systemctl reload sshd"
      fi
    fi
  fi

  # ── GitHub Secrets ───────────────────────────────────
  step 5 "GitHub Secrets"

  # Derive repo name from git remote if not already set
  if [ -z "${GITHUB_REPO:-}" ] && [ -d "$REPO_DIR/.git" ]; then
    GITHUB_REPO=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[^:/]*[:/]##; s/\.git$//; s#/settings/.*##')
  fi

  info "The deploy pipeline needs 4 secrets in your GitHub repo."
  if [ -n "${GITHUB_REPO:-}" ]; then
    info "Add them here: ${CYAN}https://github.com/${GITHUB_REPO}/settings/secrets/actions${NC}"
  else
    info "Go to: Repo → Settings → Secrets and variables → Actions → New repository secret"
  fi
  echo ""

  echo -e "  ${BOLD}1. DEPLOY_SSH_KEY${NC}"
  echo -e "  ${DIM}Paste the entire private key below (including BEGIN/END lines):${NC}"
  echo ""
  cat "$DEPLOY_KEY"
  echo ""

  echo -e "  ${BOLD}2. DEPLOY_HOST${NC}"
  if [ -n "${TS_IP:-}" ]; then
    echo -e "  Value: ${BOLD}${TS_IP}${NC}"
  else
    echo -e "  Value: ${DIM}your server's Tailscale IP (run: tailscale ip -4)${NC}"
  fi
  echo ""

  echo -e "  ${BOLD}3. TS_OAUTH_CLIENT_ID${NC}"
  echo -e "  ${BOLD}4. TS_OAUTH_SECRET${NC}"
  echo -e "  ${DIM}Create a Tailscale OAuth client:${NC}"
  echo -e "    ${CYAN}https://login.tailscale.com/admin/settings/oauth${NC}"
  echo -e "    Scopes: ${BOLD}Devices (Core): Write${NC} + ${BOLD}Auth Keys: Write${NC}"
  echo -e "    Tag: ${BOLD}tag:ci${NC}"
  echo ""
  echo -e "  ${DIM}Also ensure your Tailscale ACL policy includes:${NC}"
  echo -e "    ${DIM}\"tagOwners\": { \"tag:ci\": [\"autogroup:admin\"] }${NC}"
  echo -e "    ${DIM}And that tag:ci can reach this server on port 22.${NC}"
  echo -e "    ${CYAN}https://login.tailscale.com/admin/acls${NC}"

  wait_for_user

  # ── Enable deploy workflow ───────────────────────────
  step 6 "Enable deploy workflow"

  WORKFLOW="$REPO_DIR/.github/workflows/deploy.yml"
  WORKFLOW_CHANGED=false
  if [ -f "$WORKFLOW" ]; then
    if grep -q 'if: false' "$WORKFLOW"; then
      if confirm "Enable the deploy workflow? (gates deploy on a passing Validate)"; then
        # Replace the disabling condition with the real gate — deleting it
        # would leave the job with no `if:`, so it would deploy on EVERY
        # Validate run, including a failed one.
        sed -i "s#^\( *\)if: false\$#\1if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'#" "$WORKFLOW"
        ok "Workflow enabled (deploys only when Validate passes or on manual dispatch)"
        WORKFLOW_CHANGED=true
      else
        warn "Workflow still disabled — remove the 'if: false' line manually when ready"
      fi
    else
      ok "Workflow already enabled"
    fi
  else
    warn "deploy.yml not found at $WORKFLOW"
  fi

  # ── Enable secret-guard hooks ───────────────────────
  # Point git at the repo's .githooks/ so pre-commit/pre-push run. secret-guard
  # blocks any commit/push containing a literal .env value, so real API keys
  # can't be committed by accident. No-op on machines without a .env (CI, fresh
  # clones). See scripts/secret-guard.sh.
  if [ -d "$REPO_DIR/.githooks" ]; then
    git -C "$REPO_DIR" config core.hooksPath .githooks
    ok "Secret-guard hooks active (core.hooksPath = .githooks)"
  else
    warn ".githooks/ not found — secret-guard hooks skipped"
  fi

  # ── Config export cron ───────────────────────────────
  step 7 "Config sync export cron (optional)"

  echo -e "  ${DIM}The config export cron pulls Sonarr/Radarr settings into git every hour.${NC}"
  echo -e "  ${DIM}Requires services running + API keys in .env. Safe to add now — it'll${NC}"
  echo -e "  ${DIM}start working once the services are up.${NC}"
  echo ""

  CRON_LINE="0 * * * * ${REPO_DIR}/configs/run-export.sh >> \$HOME/config-export.log 2>&1"

  if crontab -l 2>/dev/null | grep -qF "run-export.sh"; then
    ok "Config export cron already installed"
  else
    if confirm "Install config export cron? (runs hourly)"; then
      ( crontab -l 2>/dev/null || true; echo "$CRON_LINE" ) | crontab -
      ok "Cron installed — first run will bootstrap configs/data/ from live services"
    else
      info "Skipped. Add it later with:"
      echo -e "  ${DIM}(crontab -l; echo '$CRON_LINE') | crontab -${NC}"
    fi
  fi

  # ── File permissions ─────────────────────────────────
  step 8 "File permissions"

  chmod +x "$REPO_DIR/deploy.sh"
  ok "deploy.sh"
  if [ -f "$REPO_DIR/configs/run-export.sh" ]; then
    chmod +x "$REPO_DIR/configs/run-export.sh"
    ok "configs/run-export.sh"
  fi

  # ── Initial deployment ───────────────────────────────
  step 9 "Initial deployment"

  # Check for required Gluetun VPN config before launching
  if [ -f "$REPO_DIR/.env" ]; then
    VPN_KEY=$(grep '^WIREGUARD_PRIVATE_KEY=' "$REPO_DIR/.env" 2>/dev/null | cut -d= -f2-)
    VPN_ADDR=$(grep '^WIREGUARD_ADDRESSES=' "$REPO_DIR/.env" 2>/dev/null | cut -d= -f2-)
    if [ -z "$VPN_KEY" ] || [ -z "$VPN_ADDR" ]; then
      warn "Gluetun VPN config is incomplete in .env"
      echo -e "  ${DIM}WIREGUARD_PRIVATE_KEY and WIREGUARD_ADDRESSES are required for the downloads stack.${NC}"
      echo -e "  ${DIM}Without them, Gluetun will fail to start and take qBittorrent + Prowlarr with it.${NC}"
      echo ""
      if confirm "Skip the downloads stack and start everything else?"; then
        SKIP_DOWNLOADS=true
      else
        info "Fill in the VPN values in $REPO_DIR/.env and re-run: ./setup.sh install"
        SKIP_DOWNLOADS=true
      fi
    else
      SKIP_DOWNLOADS=false
    fi
  else
    SKIP_DOWNLOADS=false
  fi

  echo -e "  ${DIM}This starts all your Docker stacks for the first time.${NC}"
  echo -e "  ${DIM}After this, every push to main auto-deploys only changed stacks.${NC}"
  echo ""

  if confirm "Start all stacks now?"; then
    info "Starting..."
    # Start each stack as its own Compose project (-p <stack>), matching how the
    # deploy pipeline runs them. A single root-project `up` would claim the same
    # container_names under a different project name, so the first GitOps deploy
    # would then fail with "name already in use".
    for dir in "$REPO_DIR"/*/; do
      [ -f "$dir/docker-compose.yml" ] || continue
      stack_name=$(basename "$dir")
      if [ "$SKIP_DOWNLOADS" = true ] && [ "$stack_name" = "downloads" ]; then
        warn "Skipping downloads stack (VPN not configured)"
        continue
      fi
      info "Starting $stack_name..."
      docker compose -p "$stack_name" -f "$dir/docker-compose.yml" up -d 2>&1 || warn "$stack_name failed to start"
    done
    echo ""
    ok "Stacks started"
    echo ""
    info "Container status:"
    docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
  else
    info "Skipped. Start a stack when ready with:"
    echo -e "  ${DIM}docker compose -p <stack> -f <stack>/docker-compose.yml up -d${NC}"
  fi

  # ── Commit and push ──────────────────────────────────
  step 10 "API keys for config sync (optional)"

  # Resolve the server's LAN IP for clickable links
  # Look for a private IP on a real interface (not docker, tailscale, vpn)
  LOCAL_IP=$(ip -4 addr show 2>/dev/null \
    | grep 'inet ' \
    | grep -v '127.0.0.1' \
    | grep -vE '(docker|br-|tailscale|wg[0-9]|tun[0-9]|veth)' \
    | grep -oP 'inet \K[0-9.]+' \
    | head -1 || true)
  LOCAL_IP="${LOCAL_IP:-localhost}"

  echo -e "  ${DIM}Now that services are running, grab their API keys.${NC}"
  echo -e "  ${DIM}Each link goes to Settings → General → API Key in that service's UI.${NC}"
  echo ""

  if confirm "Add API keys to .env now?"; then
    echo ""
    echo -e "    ${CYAN}http://${LOCAL_IP}:8989/settings/general${NC}"
    prompt ENV_SONARR_KEY "Sonarr API key (blank = skip)" ""

    echo -e "    ${CYAN}http://${LOCAL_IP}:7878/settings/general${NC}"
    prompt ENV_RADARR_KEY "Radarr API key (blank = skip)" ""

    echo -e "    ${CYAN}http://${LOCAL_IP}:9696/settings/general${NC}"
    prompt ENV_PROWLARR_KEY "Prowlarr API key (blank = skip)" ""

    prompt ENV_SEERR_KEY "Seerr/Jellyseerr API key (blank = skip)" ""

    # Update .env in place — replace empty keys with provided values
    for pair in "SONARR_API_KEY:$ENV_SONARR_KEY" "RADARR_API_KEY:$ENV_RADARR_KEY" "PROWLARR_API_KEY:$ENV_PROWLARR_KEY" "SEERR_API_KEY:$ENV_SEERR_KEY"; do
      key="${pair%%:*}"
      val="${pair#*:}"
      if [ -n "$val" ]; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$REPO_DIR/.env"
        ok "$key set"
      fi
    done
  else
    info "Skipped — add them to .env manually when ready"
  fi

  # ── Config export ─────────────────────────────────────
  step 11 "Export current configs"

  echo -e "  ${DIM}This pulls Sonarr/Radarr settings into configs/data/ so they're tracked in git.${NC}"
  echo -e "  ${DIM}Requires services running + API keys in .env.${NC}"
  echo ""

  # Check if any API keys are set
  HAS_KEYS=false
  if [ -f "$REPO_DIR/.env" ]; then
    for key in SONARR_API_KEY RADARR_API_KEY; do
      val=$(grep "^${key}=" "$REPO_DIR/.env" 2>/dev/null | cut -d= -f2-)
      if [ -n "$val" ]; then
        HAS_KEYS=true
        break
      fi
    done
  fi

  if [ "$HAS_KEYS" = true ]; then
    if confirm "Run config export now?"; then
      # Fix ownership if configs/data/ was created by Docker (root-owned)
      if [ -d "$REPO_DIR/configs/data" ] && [ ! -w "$REPO_DIR/configs/data" ]; then
        sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$REPO_DIR/configs/data"
        ok "Fixed configs/data/ ownership (was root from Docker)"
      fi
      info "Exporting configs..."
      # Override Docker-internal hostnames with localhost (we're on the host, not inside a container)
      REPO_DIR="$REPO_DIR" PYTHONPATH="$REPO_DIR" \
        RADARR_URL="http://localhost:7878" \
        SONARR_URL="http://localhost:8989" \
        python3 -m configs.sync.export 2>&1 || warn "Config export had errors (non-fatal — services may still be starting)"
      ok "Config export complete"
    else
      info "Skipped — run manually later: ${REPO_DIR}/configs/run-export.sh"
    fi
  else
    info "No API keys set — skipping config export"
    echo -e "  ${DIM}After adding API keys, run: ${REPO_DIR}/configs/run-export.sh${NC}"
  fi

  # ── Commit and push ──────────────────────────────────
  step 12 "Commit and push"

  if git -C "$REPO_DIR" diff --quiet && git -C "$REPO_DIR" diff --cached --quiet; then
    ok "No changes to commit"
  else
    if confirm "Commit and push changes (workflow enable, etc.)?"; then
      git -C "$REPO_DIR" add -A
      git -C "$REPO_DIR" commit -m "chore: initial server setup via setup.sh"
      git -C "$REPO_DIR" push
      ok "Pushed to origin"
      if [ "$WORKFLOW_CHANGED" = true ]; then
        info "The deploy workflow is now active — future pushes will auto-deploy"
      fi
    fi
  fi

  # ── Done ─────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}━━ Setup complete ━━${NC}"
  echo ""
  ok "Your server is configured for automated deploys."
  echo ""
  info "What happens now:"
  echo -e "  • Edit files locally, push to main → auto-deploys changed stacks"
  echo -e "  • Sonarr/Radarr UI changes → hourly export captures them into git"
  echo -e "  • Failed deploys → auto-rollback to previous working state"
  echo ""
  info "Useful paths:"
  echo -e "  Repo:       ${BOLD}${REPO_DIR}${NC}"
  echo -e "  .env:       ${BOLD}${REPO_DIR}/.env${NC}"
  echo -e "  Deploy key: ${BOLD}${DEPLOY_KEY}${NC}"
  echo -e "  Git key:    ${BOLD}${GIT_KEY}${NC}"
  echo ""
  info "To uninstall later: ${DIM}./setup.sh uninstall${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════
# Main — route to install or uninstall
# ══════════════════════════════════════════════════════

# Support command-line argument
case "${1:-}" in
  install)   do_install; exit 0 ;;
  uninstall) do_uninstall; exit 0 ;;
  "") ;; # No argument — show menu below
  *)
    echo "Usage: $0 [install|uninstall]"
    exit 1
    ;;
esac

# Interactive menu
echo ""
echo -e "${BOLD}  Driftarr${NC}"
echo -e "${DIM}  Automated Docker Compose deploys via GitHub Actions + Tailscale${NC}"
echo ""
echo -e "  ${BOLD}1)${NC} Install — set up everything from scratch"
echo -e "  ${BOLD}2)${NC} Uninstall — remove the deploy pipeline and optionally tear down stacks"
echo ""
echo -en "  ${CYAN}?${NC} Choose ${DIM}[1/2]${NC}: "
read -r choice

case "$choice" in
  1) do_install ;;
  2) do_uninstall ;;
  *)
    err "Invalid choice. Run: $0 [install|uninstall]"
    exit 1
    ;;
esac
