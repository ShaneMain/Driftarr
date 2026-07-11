#!/usr/bin/env bash
# Off-site backup: config + selected data volumes/databases -> object storage via
# rclone, client-side encrypted with `rclone crypt`. Authenticates with a storage
# service-account (or any rclone remote), so recovery never depends on a personal
# cloud-account password / 2FA.
#
# What it does:
#   1. Dumps configured databases (mysql/mariadb) from their containers.
#   2. Snapshots configured Docker named volumes (via an alpine sidecar).
#   3. Copies .env, every docker-compose.yml, and any extra secret files.
#   4. tar + zstd into one archive, uploads to REMOTE, prunes old archives.
#
# Configure via environment (e.g. in .env, sourced by cron) or edit the defaults
# below. Restore + full disaster-recovery runbook: backup/backup-and-recovery.md
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
STACKS_DIR="${STACKS_DIR:-$HOME/docker-stacks}"
STAGE_DIR="${STAGE_DIR:-/tmp/backup-stage}"
# rclone remote to upload to. Set up a `crypt` remote wrapping your storage
# backend (see the runbook), e.g. "myremote-crypt:app".
REMOTE="${RCLONE_REMOTE:-crypt:backups}"
# Docker named volumes to snapshot, space-separated. Empty = skip.
#   e.g. BACKUP_VOLUMES="vaultwarden_data bookstack_data"
VOLUMES="${BACKUP_VOLUMES:-}"
# Database dumps as "container:database", space-separated. Empty = skip.
#   e.g. BACKUP_DB_DUMPS="bookstack-db:bookstack"
DB_DUMPS="${BACKUP_DB_DUMPS:-}"
# Extra gitignored secret files under STACKS_DIR to include, space-separated.
#   e.g. BACKUP_EXTRA_FILES="app/app.env other/secret.env"
EXTRA_FILES="${BACKUP_EXTRA_FILES:-}"
# Retention: keep this many days of dailies; keep Sundays up to WEEKLY_DAYS.
KEEP_DAILY_DAYS="${KEEP_DAILY_DAYS:-7}"
KEEP_WEEKLY_DAYS="${KEEP_WEEKLY_DAYS:-28}"

TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${STAGE_DIR}/backup-${TS}.tar.zst"

log() { echo "[$(date +%H:%M:%S)] $*"; }
cleanup() { rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

mkdir -p "$STAGE_DIR"
WORK="${STAGE_DIR}/work"
mkdir -p "$WORK"

# ── Databases ────────────────────────────────────────────────────────────────
if [ -n "$DB_DUMPS" ]; then
  mkdir -p "$WORK/databases"
  for spec in $DB_DUMPS; do
    container="${spec%%:*}"; db="${spec#*:}"
    log "Dumping database ${db} from ${container}"
    # Uses the container's own MARIADB_ROOT_PASSWORD env; adjust for your image.
    docker exec "$container" sh -c \
      'exec mariadb-dump --single-transaction -u root -p"$MARIADB_ROOT_PASSWORD" '"$db" \
      > "$WORK/databases/${container}-${db}.sql"
  done
fi

# ── Volumes ──────────────────────────────────────────────────────────────────
if [ -n "$VOLUMES" ]; then
  mkdir -p "$WORK/volumes"
  for vol in $VOLUMES; do
    log "Snapshotting volume ${vol}"
    docker run --rm -v "${vol}:/src:ro" -v "$WORK/volumes:/dst" \
      alpine sh -c "tar cf /dst/${vol}.tar -C /src ."
  done
fi

# ── Config / secrets ─────────────────────────────────────────────────────────
log "Copying config + compose files"
mkdir -p "$WORK/configs"
[ -f "$STACKS_DIR/.env" ] && cp "$STACKS_DIR/.env" "$WORK/configs/env"
for extra in $EXTRA_FILES; do
  if [ -f "$STACKS_DIR/$extra" ]; then
    mkdir -p "$WORK/configs/$(dirname "$extra")"
    cp "$STACKS_DIR/$extra" "$WORK/configs/$extra"
  fi
done
find "$STACKS_DIR" -maxdepth 3 -name docker-compose.yml \
  -exec cp --parents {} "$WORK/configs/" \; 2>/dev/null || true

# ── Archive + upload ─────────────────────────────────────────────────────────
log "Compressing (zstd)"
tar --zstd -cf "$ARCHIVE" -C "$WORK" .
log "Archive: $(du -h "$ARCHIVE" | cut -f1)"

log "Uploading to $REMOTE"
rclone copy "$ARCHIVE" "$REMOTE/" --progress

# ── Prune ────────────────────────────────────────────────────────────────────
log "Pruning remote: keep ${KEEP_DAILY_DAYS}d daily + Sundays up to ${KEEP_WEEKLY_DAYS}d"
rclone lsf "$REMOTE/" --files-only | while read -r f; do
  date_str="${f#backup-}"; date_str="${date_str:0:8}"
  [[ -z "$date_str" ]] && continue
  age_days=$(( ( $(date +%s) - $(date -d "$date_str" +%s) ) / 86400 ))
  dow=$(date -d "$date_str" +%u)  # 1=Mon..7=Sun
  if (( age_days > KEEP_WEEKLY_DAYS )); then
    rclone delete "$REMOTE/$f"
  elif (( age_days > KEEP_DAILY_DAYS )) && (( dow != 7 )); then
    rclone delete "$REMOTE/$f"
  fi
done

log "Done."
