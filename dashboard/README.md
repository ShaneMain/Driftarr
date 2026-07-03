# Dashboard

Landing page for the fleet — [Homepage](https://gethomepage.dev) with links to
every web UI, live widgets, and per-container status dots.

- **URL:** `http://<server>:3004`
- **App list:** `config/services.yaml` (groups, links, widgets)
- **Look/layout:** `config/settings.yaml` · info bar: `config/widgets.yaml`
- **Docker integration:** the stack runs its own read-only socket proxy
  (`dashboard-dockerproxy`, `CONTAINERS=1` only, no host port). Entries with
  `container:` get a status dot + cpu/mem stats.

## Setup

Set in `.env`:

```bash
DASHBOARD_HOST=192.168.1.50        # LAN IP or DNS name of this server
# DASHBOARD_ALLOWED_HOSTS=192.168.1.50:3004   # optional; defaults to *
```

Links and widget polling both go through `DASHBOARD_HOST`'s host-published
ports (stacks are separate compose projects with no shared network). Widgets
light up for Sonarr/Radarr/Prowlarr once their `*_API_KEY` values are filled in
after first run.

## Adding an app

Add an entry under a group in `config/services.yaml`:

```yaml
- Foo:
    icon: foo.png            # dashboard-icons name, or mdi-* for material icons
    href: "http://{{HOMEPAGE_VAR_HOST}}:1234"
    description: What it does
    server: dockerproxy      # + container: for a status dot
    container: foo
    widget:                  # optional — see gethomepage.dev/widgets
      type: foo
      url: "http://{{HOMEPAGE_VAR_HOST}}:1234"
      key: "{{HOMEPAGE_VAR_FOO_KEY}}"
```

**Secrets never go in config files** — put the key in `.env`, map it in
`docker-compose.yml` (`HOMEPAGE_VAR_FOO_KEY=${FOO_API_KEY}`), and reference the
`{{HOMEPAGE_VAR_FOO_KEY}}` placeholder. Config changes are picked up on
container restart; any push touching `dashboard/` redeploys the stack.
