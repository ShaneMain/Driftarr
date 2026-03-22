#!/usr/bin/env python3
"""Config export entry point — pull app APIs → data/ JSON + git commit/push.

Auto-discovers all modules in configs.sync.modules and calls export() on each.
Runs on a cron (e.g. every hour) to capture UI changes back into git.

Usage:
    python -m configs.sync.export              # export + commit + push
    python -m configs.sync.export --dry-run    # export to /tmp, show diff
"""

import os
import pathlib
import subprocess
import sys
import time

from configs.sync.base import log

REPO_DIR = pathlib.Path(os.environ.get("REPO_DIR", f"/home/{os.environ.get('USER', 'root')}/docker-stacks"))
CONFIGS_DIR = REPO_DIR / "configs"
DATA_DIR = CONFIGS_DIR / "data"
DRY_RUN = "--dry-run" in sys.argv
SYNC_MARKER = pathlib.Path("/tmp/config-sync-ran")


def git(*args) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO_DIR, capture_output=True, text=True)


def read_env_keys():
    """Set API key env vars from .env if not already set."""
    env_file = REPO_DIR / ".env"
    if not env_file.exists():
        return
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if "=" not in line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            # Strip surrounding quotes and inline comments
            value = value.strip()
            if (value.startswith('"') and value.endswith('"')) or \
               (value.startswith("'") and value.endswith("'")):
                value = value[1:-1]
            elif "#" in value:
                # Only strip inline comments outside of quoted values
                value = value[:value.index("#")].rstrip()
            if key.endswith("_API_KEY") and not os.environ.get(key):
                os.environ[key] = value


def discover_and_export(data_dir: pathlib.Path):
    """Discover modules and run export() on each reachable one."""
    import importlib
    import pkgutil
    from configs.sync.base import AppModule
    import configs.sync.modules as pkg

    modules = []
    for _, modname, _ in pkgutil.iter_modules(pkg.__path__):
        mod = importlib.import_module(f"configs.sync.modules.{modname}")
        for attr in dir(mod):
            cls = getattr(mod, attr)
            if (
                isinstance(cls, type)
                and issubclass(cls, AppModule)
                and cls is not AppModule
                and cls.name
                and not any(c.name == cls.name for c in modules)
            ):
                modules.append(cls(data_dir, "export"))

    log("config-export", f"discovered modules: {', '.join(m.name for m in modules)}")

    for mod in modules:
        if not mod.is_reachable():
            log("config-export", f"{mod.name}: not reachable, skipping")
            continue
        try:
            mod.export()
        except Exception as e:
            log("config-export", f"ERROR exporting {mod.name}: {e}")


def dry_run_compare(tmp_dir: pathlib.Path):
    """Compare exported files in tmp_dir against current data/ files."""
    changed = False
    for svc_dir in sorted(tmp_dir.iterdir()):
        if not svc_dir.is_dir():
            continue
        svc = svc_dir.name
        for f in sorted(svc_dir.glob("*.json")):
            src = DATA_DIR / svc / f.name
            if src.exists():
                if src.read_text() != f.read_text():
                    log("config-export", f"CHANGED: {svc}/{f.name}")
                    changed = True
            else:
                log("config-export", f"NEW: {svc}/{f.name}")
                changed = True
    if not changed:
        log("config-export", "no changes detected")


def git_commit_and_push():
    """Stage data/ changes, commit, and push if anything changed."""
    if SYNC_MARKER.exists():
        marker_age = time.time() - SYNC_MARKER.stat().st_mtime
        if marker_age < 300:
            log("config-export", f"sync ran {int(marker_age)}s ago, skipping export to avoid loop")
            return

    git("add", "configs/data/")

    result = git("diff", "--cached", "--quiet", "--", "configs/data/")
    if result.returncode == 0:
        git("reset", "HEAD", "--", "configs/data/")
        log("config-export", "no changes detected")
        return

    log("config-export", "changes detected, committing...")
    stat = git("diff", "--cached", "--stat", "--", "configs/data/")
    if stat.stdout:
        print(stat.stdout, flush=True)

    git("commit", "-m",
        "chore(configs): auto-export config changes from UI\n\n"
        "Exported by config-export cron. Changes were made via application UIs.")

    result = git("push", "origin", "main")
    if result.returncode == 0:
        log("config-export", "pushed to origin/main")
    else:
        log("config-export", f"ERROR: git push failed: {result.stderr}")
        sys.exit(1)


def main():
    read_env_keys()
    log("config-export", "exporting configs...")

    if DRY_RUN:
        tmp_dir = pathlib.Path("/tmp/config-export")
        tmp_dir.mkdir(parents=True, exist_ok=True)
        discover_and_export(tmp_dir)
        log("config-export", "dry-run: comparing with current files...")
        dry_run_compare(tmp_dir)
    else:
        discover_and_export(DATA_DIR)
        git_commit_and_push()


if __name__ == "__main__":
    main()
