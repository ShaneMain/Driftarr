# Troubleshooting

Common issues and how to fix them.

## Deploy Pipeline

### Deploy fails with "Permission denied (publickey)"

The GitHub Actions runner can't authenticate as the `deploy` user.

- Verify `DEPLOY_SSH_KEY` secret contains the full private key (including `-----BEGIN/END-----` lines)
- Check the public key is in `/home/deploy/.ssh/authorized_keys`
- Confirm sshd is running: `sudo systemctl status sshd`
- Confirm the firewall allows SSH on the Tailscale interface (see `setup.sh` step 1)

### Deploy fails with "fatal: Not possible to fast-forward"

The server's local branch has diverged from `origin/main`. This happens if someone committed directly on the server.

```bash
cd ~/docker-stacks
git fetch origin
git reset --hard origin/main
```

### Deploy is a no-op (nothing restarts)

`deploy.sh` diffs changed files between commits. If the only change is in a file that doesn't map to a stack directory, nothing deploys. Config-sync still runs on every deploy regardless.

If you pushed from the server itself, the pull is a no-op — the script falls back to `HEAD~1..HEAD` automatically.

### Auto-export commit triggers a deploy loop

It shouldn't — `deploy.sh` detects commits matching `chore(configs): auto-export` and exits early. If you're seeing loops, check that the commit message format hasn't been changed in `export.py`.

## Config Sync

### Config-sync container exits with code 1

Check the container logs:

```bash
docker logs config-sync --tail 50
```

Common causes:
- Service not reachable (still starting, wrong IP/port)
- API key missing or invalid in `.env`
- Malformed JSON in `configs/data/`

### Export skips with "sync ran Xs ago"

The marker file `/tmp/config-sync-ran` prevents export from running within 5 minutes of a sync. This is loop prevention. Wait 5 minutes or remove the marker:

```bash
rm -f /tmp/config-sync-ran
```

### Export commits but push fails

The cron user needs git push access. Ensure the SSH key (`~/.ssh/driftarr_git`) is configured as a deploy key with write access on the GitHub repo, and the `~/.ssh/config` alias is set up.

## VPN / Downloads

### Gluetun fails to start

Check VPN credentials in `.env`:
- `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES` must both be set
- Verify your VPN provider config: https://github.com/qdm12/gluetun-wiki

```bash
docker logs gluetun --tail 30
```

### qBittorrent / Prowlarr unreachable

Both use `network_mode: service:gluetun` — if Gluetun is down, they have no network. Fix Gluetun first.

Check Gluetun health:
```bash
docker exec gluetun wget -qO- http://www.google.com
```

## General

### Container stuck in "unhealthy" state

Check the healthcheck command and logs:

```bash
docker inspect --format='{{json .State.Health}}' <container> | python3 -m json.tool
docker logs <container> --tail 20
```

### "No space left on device"

Docker images and build cache accumulate. Prune unused resources:

```bash
docker system prune -af --volumes
```

### Services can't reach each other

Each stack runs as its own Compose project, so its services share that
project's default network and reach one another by service name. Verify a
stack's network and attachments:

```bash
docker compose -p <stack> ps
docker network inspect <stack>_default
```

Services in *different* stacks are not on the same network by default — reach
those over the host (published ports) or add a shared external network (see
`deploy/05-networks.sh` and `networks.conf`).
