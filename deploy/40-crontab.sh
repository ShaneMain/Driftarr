#!/usr/bin/env bash
# deploy/40-crontab.sh — declarative crontab sync
# Writes: CRONTAB_OK

# The repo crontab is a template: $USER / $HOME (and ${USER} / ${HOME}) are
# substituted with the deploying user at install time. cron itself does not
# expand variables, and Debian's cron doesn't even export USER, so the file
# must never be installed verbatim.
render_crontab() {
  local user home
  user=$(id -un)
  home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
  home="${home:-${HOME:-/home/$user}}"
  # Token-boundary aware: $HOMEDIR / $USERNAME are left alone, only $USER,
  # ${USER}, $HOME, ${HOME} as whole tokens are replaced. Values are sed-escaped.
  local u_esc h_esc
  u_esc=$(printf '%s' "$user" | sed 's/[&~\\]/\\&/g')
  h_esc=$(printf '%s' "$home" | sed 's/[&~\\]/\\&/g')
  # (The bare-token rules run twice so adjacent tokens like $USER$HOME, where
  # the first match consumes the boundary character, are both replaced.)
  local r_user="s~\\\$USER([^A-Za-z0-9_]|$)~$u_esc\\1~g" r_home="s~\\\$HOME([^A-Za-z0-9_]|$)~$h_esc\\1~g"
  sed -E \
    -e "s~\\\$\\{USER\\}~$u_esc~g" -e "$r_user" -e "$r_user" \
    -e "s~\\\$\\{HOME\\}~$h_esc~g" -e "$r_home" -e "$r_home" \
    "$1"
}

CRONTAB_FILE="$REPO_DIR/crontab"
if [ -f "$CRONTAB_FILE" ]; then
  CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)
  NEW_CRONTAB=$(render_crontab "$CRONTAB_FILE")
  if [ "$CURRENT_CRONTAB" != "$NEW_CRONTAB" ]; then
    info "Installing updated crontab..."
    printf '%s\n' "$NEW_CRONTAB" | crontab -
    ok "Crontab updated"
    CRONTAB_OK=true
  else
    log "Crontab unchanged — skipping"
    CRONTAB_OK=true
  fi
fi
sep
