# Server Setup (Manual Reference)

> **Recommended:** Run `./setup.sh` instead — it handles all of these steps interactively. This document is the manual reference for troubleshooting or if you prefer to do it yourself.

## Prerequisites

- Docker + Docker Compose v2
- Git
- Python 3 (stdlib only — no pip packages needed)
- [Tailscale](https://tailscale.com/)

## 1. Install Tailscale

```bash
# Fedora/RHEL
sudo dnf install tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up

# Ubuntu/Debian
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Note your server's Tailscale IP:

```bash
tailscale ip -4
```

## 2. Clone your repo

Clone your own repo (created from the template), not the template itself:

```bash
git clone git@github.com:YOUR_ORG/YOUR_REPO.git ~/docker-stacks
cd ~/docker-stacks
cp .env.example .env
# Edit .env with your actual values
```

## 3. Symlink .env into each stack

```bash
for dir in */; do
  [ -f "$dir/docker-compose.yml" ] && ln -sf "$PWD/.env" "$dir/.env"
done
```

## 4. Create the deploy user

```bash
sudo useradd -r -s /bin/bash -m deploy
```

## 5. Generate SSH keys

Generate a key pair for GitHub Actions to authenticate as the deploy user:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/driftarr_deploy -N ""
```

Install the public key with command restriction:

```bash
sudo mkdir -p /home/deploy/.ssh

echo "command=\"sudo -u $(whoami) $PWD/deploy.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $(cat ~/.ssh/driftarr_deploy.pub)" \
  | sudo tee /home/deploy/.ssh/authorized_keys > /dev/null

sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

## 6. Configure sudoers

```bash
echo "deploy ALL=($(whoami)) NOPASSWD: $PWD/deploy.sh" \
  | sudo tee /etc/sudoers.d/deploy > /dev/null
sudo chmod 440 /etc/sudoers.d/deploy
```

## 7. Lock down SSH

```bash
sudo tee /etc/ssh/sshd_config.d/60-deploy.conf > /dev/null << EOF
Match User deploy
    ForceCommand sudo -u $(whoami) $PWD/deploy.sh
    PermitTTY no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
EOF
sudo systemctl reload sshd
```

This creates three independent security layers:

1. `authorized_keys` — command restriction at the key level
2. sshd `ForceCommand` — server-level enforcement
3. sudoers — privilege scoping to `deploy.sh` only

## 8. GitHub Secrets

Add these to your repo under Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `DEPLOY_SSH_KEY` | Contents of `~/.ssh/driftarr_deploy` (private key) |
| `DEPLOY_HOST` | Your server's Tailscale IP |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth client secret |

### Creating the Tailscale OAuth client

1. Go to [Tailscale OAuth clients](https://login.tailscale.com/admin/settings/oauth)
2. Create a new client with scopes: **Devices (Core): Write** and **Auth Keys: Write**
3. Assign the tag `tag:ci`
4. Copy the client ID and secret into the GitHub secrets above

Ensure your [Tailscale ACL policy](https://login.tailscale.com/admin/acls) includes:

```json
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  }
}
```

And that `tag:ci` nodes can reach your server on port 22.

OAuth clients don't expire like auth keys — no rotation needed.

## 9. Enable the deploy workflow

The template ships with the workflow disabled. Remove the `if: false` line:

```yaml
# .github/workflows/deploy.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    # if: false  ← delete this line
```

Commit and push.

## 10. First deploy

```bash
docker compose up -d
```

After this, every push to `main` auto-deploys only the changed stacks.

## 11. Config export cron (optional)

Set up the hourly export to capture UI changes back into git:

```bash
crontab -e
```

```
0 * * * * /path/to/docker-stacks/configs/run-export.sh >> /var/log/config-export.log 2>&1
```

The first run bootstraps `configs/data/` by pulling live configs from service APIs. The cron user needs git push access (SSH key) and the services running with API keys in `.env`.

## Local deploy command (optional)

Add to your shell profile for one-command deploys:

```bash
driftarr() {
  local repo="YOUR_ORG/YOUR_REPO"
  gh workflow run deploy.yml --repo "$repo"
  echo "Waiting for run to start..."
  sleep 2
  local run_id
  run_id=$(gh run list --repo "$repo" --workflow=deploy.yml --limit=1 --json databaseId --jq '.[0].databaseId')
  gh run watch --repo "$repo" "$run_id" --exit-status
  local rc=$?
  echo ""
  echo "=== Deploy Logs ==="
  gh run view "$run_id" --repo "$repo" --log 2>&1 | grep "Deploy via SSH" | sed 's/^deploy\tDeploy via SSH\t[^ ]* //'
  return $rc
}
```

Requires [GitHub CLI](https://cli.github.com/) authenticated with `gh auth login`.
