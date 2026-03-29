# stack.conf Reference

Each stack directory can include an optional `stack.conf` file to declare its deploy behavior. Stacks without a `stack.conf` use sensible defaults.

## Options

| Key | Default | Description |
|-----|---------|-------------|
| `STACK_BUILD_REQUIRED` | `no` | Set to `yes` if the stack needs `docker compose build` before `up -d` (e.g. custom Dockerfiles). Overrides the global `DEPLOY_BUILD_STACKS` env var. |
| `STACK_HEALTH_TIMEOUT` | `90` | Seconds to wait for containers to leave "starting" state before checking health. |
| `STACK_HOT_RELOAD_PATTERNS` | _(empty)_ | Space-separated file globs (relative to stack dir) that can be hot-reloaded without restarting the stack. When a changed file matches, the stack is removed from the deploy list and `STACK_HOT_RELOAD_CMD` runs instead. |
| `STACK_HOT_RELOAD_CMD` | _(empty)_ | Shell command to run when a hot-reload pattern matches. Typically `docker exec <container> kill -SIGHUP 1`. |
| `STACK_SCRIPT_CATEGORY` | _(empty)_ | Label for logging when `.sh` files in this stack change (e.g. `monitoring`, `management`). |

## Hook Scripts

Stacks can also include executable hook scripts:

| File | When | Failure behavior |
|------|------|-----------------|
| `pre-deploy.sh` | Before `docker compose up -d` | Aborts the stack deploy (triggers rollback) |
| `post-deploy.sh` | After successful health checks | Logged as warning (non-fatal) |

## Example

```ini
# notifications/stack.conf
STACK_BUILD_REQUIRED=yes
STACK_HEALTH_TIMEOUT=60
```

```ini
# monitoring/stack.conf
STACK_BUILD_REQUIRED=no
STACK_HEALTH_TIMEOUT=120
STACK_HOT_RELOAD_PATTERNS=prometheus.yml alert-rules.yml alertmanager.yml
STACK_HOT_RELOAD_CMD=docker exec prometheus kill -SIGHUP 1 2>/dev/null; docker exec alertmanager kill -SIGHUP 1 2>/dev/null
STACK_SCRIPT_CATEGORY=monitoring
```

## Migration

The global `DEPLOY_BUILD_STACKS` env var still works. `stack.conf` takes precedence when present — you can migrate stacks one at a time.
