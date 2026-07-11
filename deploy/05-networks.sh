#!/usr/bin/env bash
# deploy/05-networks.sh — ensure external Docker networks exist
#
# Stacks reference cross-stack networks as `external: true`, but nothing in the
# repo creates them — they are manual server state, so a daemon reinstall or a
# fresh host loses them (and their IPAM), breaking every stack with a fixed
# ipv4_address. This module reads a committed networks.conf and idempotently
# creates any that are missing, before change detection/deploy.
#
# networks.conf format — one network per line, blanks and #comments ignored:
#     <name> [subnet]
# e.g.
#     shared 172.20.0.0/16
#     signal
#
# No-op when networks.conf is absent (a repo with no cross-stack networks
# ships without one).

NETWORKS_CONF="$REPO_DIR/networks.conf"
[ -f "$NETWORKS_CONF" ] || return 0

info "Ensuring external Docker networks exist..."
while read -r _name _subnet _rest; do
  case "$_name" in ''|'#'*) continue ;; esac
  if docker network inspect "$_name" >/dev/null 2>&1; then
    continue
  fi
  if [ -n "$_subnet" ]; then
    log "Creating missing network $_name ($_subnet)"
    docker network create --subnet="$_subnet" "$_name" >/dev/null 2>&1 \
      || warn "Failed to create network $_name"
  else
    log "Creating missing network $_name"
    docker network create "$_name" >/dev/null 2>&1 \
      || warn "Failed to create network $_name"
  fi
done < "$NETWORKS_CONF"
sep
