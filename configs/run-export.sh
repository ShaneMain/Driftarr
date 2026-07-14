#!/bin/bash
# Wrapper for cron — runs export.py with correct PYTHONPATH.
# No external dependencies — uses Python stdlib only (urllib).
#
# Crontab entry:
#   0 * * * * /home/$USER/docker-stacks/configs/run-export.sh >> /home/$USER/config-export.log 2>&1

REPO_DIR="${REPO_DIR:-/home/$USER/docker-stacks}"
export PYTHONPATH="$REPO_DIR"
export REPO_DIR

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
