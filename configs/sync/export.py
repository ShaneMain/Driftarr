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

from configs.sync.base import discover_modules, log

REPO_DIR = pathlib.Path(os.environ.get("REPO_DIR", f"/home/{os.environ.get('USER', 'root')}/docker-stacks"))
CONFIGS_DIR = REPO_DIR / "configs"
DATA_DIR = CONFIGS_DIR / "data"
BRANCH = os.environ.get("DEPLOY_BRANCH", "main")
DRY_RUN = "--dry-run" in sys.argv
# Written by sync.py inside the container at <data>/.sync-ran; the data dir
# is bind-mounted so this host path resolves to the same file.
SYNC_MARKER = DATA_DIR / ".sync-ran"


def git(*args) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO_DIR, capture_output=True, text=True)


def read_env_keys():
    """Load .env into the environment (without overriding existing vars).

    Modules reference more than *_API_KEY: Seerr falls back to
    JELLYSEERR_KEY, NZBget reads NZBGET_CONTROL_USER/PASS, and ${VAR}
    placeholders in exported files may name anything in .env. Values are
    only ever used as env vars, so importing the whole file is safe.
    """
    env_file = REPO_DIR / ".env"
    if not env_file.exists():
        return
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if "=" not in line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            key = key.strip().removeprefix("export ").strip()
            # Strip surrounding quotes and inline comments
            value = value.strip()
            if (value.startswith('"') and value.endswith('"')) or \
               (value.startswith("'") and value.endswith("'")):
                value = value[1:-1]
            elif " #" in value:
                # Only strip inline comments preceded by whitespace (shell convention)
                # e.g. KEY=value # comment → value, but KEY=abc#123 → abc#123
                value = value[:value.index(" #")].rstrip()
            if key and not os.environ.get(key):
                os.environ[key] = value


def discover_and_export(data_dir: pathlib.Path) -> list[str]:
    """Discover modules and run export() on each reachable one.

    Returns the names of modules whose export() raised. A module writes its
    files one by one, so a failure mid-way leaves a fresh/stale mix on disk
    that must not be committed.
    """
    modules = discover_modules(data_dir, "export")
    log("config-export", f"discovered modules: {', '.join(m.name for m in modules)}")

    failed: list[str] = []
    for mod in modules:
        if not mod.is_reachable():
            log("config-export", f"{mod.name}: not reachable, skipping")
            continue
        try:
            mod.export()
        except Exception as e:
            log("config-export", f"ERROR exporting {mod.name}: {e}")
            failed.append(mod.name)
    return failed


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


def sync_ran_recently(window: int = 300) -> bool:
    """True if sync.py touched the loop-prevention marker within `window` seconds.

    Checked *before* exporting: an export right after a sync would only
    re-capture what was just applied, and writing files we then refuse to
    commit would leave the worktree dirty for the next deploy's pull.
    """
    if not SYNC_MARKER.exists():
        return False
    marker_age = time.time() - SYNC_MARKER.stat().st_mtime
    if marker_age < window:
        log("config-export", f"sync ran {int(marker_age)}s ago, skipping export to avoid loop")
        return True
    return False


def git_commit_and_push():
    """Stage data/ changes, commit, and push if anything changed."""
    if sync_ran_recently():
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

    # Self-heal before giving up: if the push was rejected because origin
    # moved ahead (e.g. a deploy landed between our last pull and now),
    # rebase this commit onto the remote tip and retry. A rejected push
    # that stays diverged wedges every future deploy — deploy/00-pull.sh
    # pulls with --ff-only and hard-fails on divergence.
    result = git("push", "origin", BRANCH)
    if result.returncode == 0:
        log("config-export", f"pushed to origin/{BRANCH}")
        return

    log("config-export", f"push rejected — rebasing onto origin/{BRANCH} and retrying: {result.stderr.strip()}")
    git("fetch", "origin", BRANCH)
    # --autostash: an unrelated dirty file outside configs/data/ must not
    # abort the rebase and leave a local commit ahead of origin.
    rebase = git("rebase", "--autostash", f"origin/{BRANCH}")
    if rebase.returncode != 0:
        git("rebase", "--abort")
        log("config-export", f"ERROR: rebase onto origin/{BRANCH} failed — server is diverged, "
                             f"deploy will fail until resolved manually: {rebase.stderr.strip()}")
        sys.exit(1)
    result = git("push", "origin", BRANCH)
    if result.returncode == 0:
        log("config-export", f"pushed to origin/{BRANCH} (after rebase)")
    else:
        log("config-export", f"ERROR: git push failed after rebase: {result.stderr}")
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
        if sync_ran_recently():
            return
        failed = discover_and_export(DATA_DIR)
        if failed:
            # Partial export on disk — don't commit a fresh/stale mix. The
            # next successful hourly run will pick the changes up.
            log("config-export", f"ERROR: export failed for {', '.join(failed)} — not committing")
            git("checkout", "--", "configs/data/")
            sys.exit(1)
        git_commit_and_push()


if __name__ == "__main__":
    main()
