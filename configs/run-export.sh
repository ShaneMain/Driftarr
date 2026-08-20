#!/bin/bash
# Wrapper for cron — runs export.py with correct PYTHONPATH.
# No external dependencies — uses Python stdlib only (urllib).
#
# Crontab entry:
#   0 * * * * /home/$USER/docker-stacks/configs/run-export.sh >> /home/$USER/config-export.log 2>&1

REPO_DIR="${REPO_DIR:-/home/${USER:-$(id -un)}/docker-stacks}"
export PYTHONPATH="$REPO_DIR"
export REPO_DIR

# Share the deploy lock (same default as deploy.sh / deploy/lib.sh). A deploy
# may have configs/data/ or a stack dir checked out at an older commit for a
# rollback; exporting then would commit that stale state as an "auto-export".
# Non-blocking: cron runs again soon, so just skip. fd 9 is inherited by the
# exec'd python, so the lock is held for the whole export.
DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-$REPO_DIR/.deploy.lock}"
exec 9>"$DEPLOY_LOCK_FILE"
if ! flock -n 9; then
  echo "$(date -Is) config-export: deploy in progress ($DEPLOY_LOCK_FILE held) — skipping this run"
  exit 0
fi

# Export runs on the host — override Docker-internal hostnames with localhost
export RADARR_URL="${RADARR_URL:-http://localhost:7878}"
export SONARR_URL="${SONARR_URL:-http://localhost:8989}"
export BAZARR_URL="${BAZARR_URL:-http://localhost:6767}"
export PROWLARR_URL="${PROWLARR_URL:-http://localhost:9696}"

# Fix ownership if configs/data/ was created by Docker container (root-owned)
DATA_DIR="$REPO_DIR/configs/data"
if [ -d "$DATA_DIR" ] && [ ! -w "$DATA_DIR" ]; then
  sudo chown -R "$(id -un):$(id -gn)" "$DATA_DIR" 2>/dev/null || true
fi

exec python3 -m configs.sync.export "$@"
