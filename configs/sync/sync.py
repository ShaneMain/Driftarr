#!/usr/bin/env python3
"""Config sync entry point — push data/ JSON → app APIs.

Auto-discovers all modules in configs.sync.modules and calls sync() on each.

Usage:
    python -m configs.sync.sync          # apply changes
    python -m configs.sync.sync diff     # dry-run
"""

import importlib
import pathlib
import pkgutil
import sys

from configs.sync.base import AppModule, log

CONFIGS_DIR = pathlib.Path("/configs")
DATA_DIR = CONFIGS_DIR / "data"
SYNC_MARKER = pathlib.Path("/tmp/config-sync-ran")


def discover_modules(data_dir: pathlib.Path, mode: str) -> list[AppModule]:
    """Import all modules in configs.sync.modules and instantiate AppModule subclasses."""
    import configs.sync.modules as pkg

    modules = []
    for importer, modname, ispkg in pkgutil.iter_modules(pkg.__path__):
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
                modules.append(cls(data_dir, mode))
    return modules


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "sync"
    log("config-sync", f"starting (mode: {mode})...")
    log("config-sync", f"data dir: {DATA_DIR} (exists: {DATA_DIR.exists()})")

    modules = discover_modules(DATA_DIR, mode)
    log("config-sync", f"discovered modules: {', '.join(m.name for m in modules)}")
    for mod in modules:
        files = sorted(mod.data_dir.glob("*.json")) if mod.data_dir.exists() else []
        log("config-sync", f"  {mod.name}: {mod.url} | data: {mod.data_dir} ({len(files)} files: {', '.join(f.name for f in files)})")

    # Check readiness and sync each module (skip unreachable ones)
    skipped = []
    for mod in modules:
        if not mod.wait_until_ready():
            log("config-sync", f"SKIP {mod.name}: not reachable after timeout")
            skipped.append(mod.name)
            continue
        log("config-sync", f"syncing {mod.name}...")
        try:
            mod.sync()
        except Exception as e:
            log("config-sync", f"ERROR syncing {mod.name}: {e}")

    if skipped:
        log("config-sync", f"skipped {len(skipped)} unreachable module(s): {', '.join(skipped)}")

    # Leave marker so export knows we just ran
    try:
        SYNC_MARKER.touch()
    except OSError:
        pass

    log("config-sync", "done")


if __name__ == "__main__":
    main()
