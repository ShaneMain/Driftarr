#!/usr/bin/env python3
"""Config sync entry point — push data/ JSON → app APIs.

Auto-discovers all modules in configs.sync.modules and calls sync() on each.

Usage:
    python -m configs.sync.sync          # apply changes
    python -m configs.sync.sync diff     # dry-run

Exit code 0 only if every *required* module applied successfully. A module
is required when its data directory contains at least one *.json file —
i.e., the repo has declared config for it. Required modules that never
become reachable, or whose sync() raises, fail the whole run (exit 1).

Modules without declared data (empty data_dir) are optional and skipping
them is fine — nothing was asked of them.

This upholds the deploy-is-end-to-end-or-it-fails principle: a partial
sync is treated as a failure, not a success.
"""

import pathlib
import sys
import time

from configs.sync.base import AppModule, discover_modules, log

CONFIGS_DIR = pathlib.Path("/configs")
DATA_DIR = CONFIGS_DIR / "data"
SYNC_MARKER = pathlib.Path("/tmp/config-sync-ran")

# Deploy-scale retry window for modules that are slow to become reachable
# (container restarts, image pulls, healthcheck warm-up).
REACHABILITY_ATTEMPTS = 4
REACHABILITY_WAIT_PER_ATTEMPT = 30  # seconds passed to module.wait_until_ready
REACHABILITY_BACKOFF = 20  # seconds between attempts after the first


def is_required(mod: AppModule) -> bool:
    """A module is required when the repo has declared data for it."""
    return mod.data_dir.exists() and any(mod.data_dir.glob("*.json"))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "sync"
    log("config-sync", f"starting (mode: {mode})...")
    log("config-sync", f"data dir: {DATA_DIR} (exists: {DATA_DIR.exists()})")

    modules = discover_modules(DATA_DIR, mode)
    log("config-sync", f"discovered modules: {', '.join(m.name for m in modules)}")
    for mod in modules:
        files = sorted(mod.data_dir.glob("*.json")) if mod.data_dir.exists() else []
        required_marker = " [REQUIRED]" if is_required(mod) else ""
        log(
            "config-sync",
            f"  {mod.name}: {mod.url} | data: {mod.data_dir} "
            f"({len(files)} files: {', '.join(f.name for f in files)}){required_marker}",
        )

    pending = list(modules)
    synced: list[str] = []
    sync_errors: list[tuple[str, str]] = []

    for attempt in range(1, REACHABILITY_ATTEMPTS + 1):
        if not pending:
            break
        if attempt > 1:
            log(
                "config-sync",
                f"attempt {attempt}/{REACHABILITY_ATTEMPTS}: "
                f"{len(pending)} module(s) still unreachable, waiting {REACHABILITY_BACKOFF}s "
                f"({', '.join(m.name for m in pending)})",
            )
            time.sleep(REACHABILITY_BACKOFF)

        still_pending: list[AppModule] = []
        for mod in pending:
            if not mod.wait_until_ready(timeout=REACHABILITY_WAIT_PER_ATTEMPT):
                still_pending.append(mod)
                continue
            log("config-sync", f"syncing {mod.name}...")
            try:
                mod.sync()
                synced.append(mod.name)
            except Exception as e:
                log("config-sync", f"ERROR syncing {mod.name}: {e}")
                sync_errors.append((mod.name, str(e)))
        pending = still_pending

    unreachable_required = [m for m in pending if is_required(m)]
    unreachable_optional = [m for m in pending if not is_required(m)]

    if unreachable_optional:
        log(
            "config-sync",
            f"skipped {len(unreachable_optional)} optional unreachable module(s): "
            f"{', '.join(m.name for m in unreachable_optional)}",
        )

    # Leave marker so export knows we just ran (even on partial failure —
    # a simultaneous export would only reinforce live state).
    try:
        SYNC_MARKER.touch()
    except OSError:
        pass

    if unreachable_required or sync_errors:
        log("config-sync", "FAIL: declared config did not apply cleanly")
        for m in unreachable_required:
            log(
                "config-sync",
                f"  {m.name}: unreachable after {REACHABILITY_ATTEMPTS} attempts "
                f"(data declared in {m.data_dir}) — required",
            )
        for name, err in sync_errors:
            log("config-sync", f"  {name}: sync() raised: {err}")
        sys.exit(1)

    log("config-sync", f"done — synced {len(synced)} module(s): {', '.join(synced) or '(none)'}")


if __name__ == "__main__":
    main()
