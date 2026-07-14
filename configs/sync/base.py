"""Base class for config sync modules.

Subclass AppModule and implement:
- sync(mode): push data/ JSON → app APIs. mode is "sync" or "diff".
- export(): pull app APIs → data/ JSON files.

The engine auto-discovers modules and calls these methods.
"""

import json
import os
import pathlib
import time
import urllib.error
import urllib.request
from typing import Any


def log(prefix: str, msg: str):
    print(f"[{prefix}] {msg}", flush=True)


class AppModule:
    name: str = ""  # e.g. "radarr" — also the data subdirectory name
    url_env: str = ""  # env var for URL, e.g. "RADARR_URL"
    key_env: str = ""  # env var for API key, e.g. "RADARR_API_KEY"
    default_url: str = ""  # fallback URL if env var not set
    config_xml_path: str = ""  # optional: path to config.xml for API key
    expected_files: list[str] = []  # files that should exist after export (for bootstrap detection)

    def __init__(self, data_dir: pathlib.Path, mode: str = "sync"):
        self.data_dir = data_dir / self.name
        self.mode = mode  # "sync" or "diff"
        self.url = os.environ.get(self.url_env, self.default_url)
        self.api_key = os.environ.get(self.key_env, "")
        self._read_api_key_fallback()

    def _read_api_key_fallback(self):
        if self.api_key or not self.config_xml_path:
            return
        try:
            import xml.etree.ElementTree as ET

            tree = ET.parse(self.config_xml_path)
            node = tree.find("ApiKey")
            if node is not None and node.text:
                self.api_key = node.text
        except Exception:
            pass

    def log(self, msg: str):
        log(self.name, msg)

    # ── API helpers ───────────────────────────────────

    def _headers(self) -> dict:
        return {"X-Api-Key": self.api_key, "Content-Type": "application/json"}

    def _request(self, url: str, method: str = "GET", data: Any = None) -> Any:
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(url, data=body, headers=self._headers(), method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {url} → {e.code}: {e.read().decode()[:200]}") from e

    def api_get(self, endpoint: str) -> Any:
        return self._request(f"{self.url}/api/v3/{endpoint}")

    def api_put(self, endpoint: str, data: Any) -> Any:
        return self._request(f"{self.url}/api/v3/{endpoint}", "PUT", data)

    def api_post(self, endpoint: str, data: Any) -> Any:
        return self._request(f"{self.url}/api/v3/{endpoint}", "POST", data)

    def api_delete(self, endpoint: str):
        self._request(f"{self.url}/api/v3/{endpoint}", "DELETE")

    # ── Health ────────────────────────────────────────

    def wait_until_ready(self, timeout: int = 60) -> bool:
        if not self.api_key:
            self.log(f"no API key configured ({self.key_env}), skipping")
            return False

        import socket
        from urllib.parse import urlparse

        parsed = urlparse(self.url)
        host = parsed.hostname
        port = parsed.port or 80

        # Quick DNS check — if hostname doesn't resolve, skip immediately
        try:
            socket.setdefaulttimeout(5)
            socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
        except (socket.gaierror, OSError):
            self.log(f"ERROR: {self.name} DNS lookup failed for {host}")
            return False
        finally:
            socket.setdefaulttimeout(None)

        self.log(f"waiting for {self.name}...")
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                req = urllib.request.Request(
                    f"{self.url}/api/v3/system/status",
                    headers=self._headers(),
                )
                with urllib.request.urlopen(req, timeout=5):
                    self.log(f"{self.name} ready")
                    return True
            except Exception:
                pass
            time.sleep(1)
        self.log(f"ERROR: {self.name} not ready after {timeout}s")
        return False

    def is_reachable(self) -> bool:
        try:
            req = urllib.request.Request(
                f"{self.url}/api/v3/system/status",
                headers=self._headers(),
            )
            with urllib.request.urlopen(req, timeout=5):
                return True
        except (urllib.error.URLError, OSError):
            self.log(f"ERROR: not reachable at {self.url}")
            return False

    # ── JSON I/O ──────────────────────────────────────

    def is_bootstrap_mode(self) -> bool:
        """Check if this is first run (no config files exported yet).

        Returns True if:
        - The data directory doesn't exist, or
        - The data directory has no JSON files (only .gitkeep, etc.), or
        - Expected files (if defined) don't all exist

        This prevents accidental deletion on initial deploy before export runs.
        """
        if not self.data_dir.exists():
            return True

        # Check if directory is empty or only has non-JSON files
        json_files = list(self.data_dir.glob("*.json"))
        if len(json_files) == 0:
            return True

        # If expected_files is defined, check that all expected files exist
        if self.expected_files:
            for expected in self.expected_files:
                if not (self.data_dir / expected).exists():
                    self.log(f"bootstrap mode: missing expected file '{expected}'")
                    return True

        return False

    def load_json(self, filename: str) -> Any | None:
        path = self.data_dir / filename
        if not path.exists():
            self.log(f"{filename}: not found — treating as empty (delete all)")
            return None
        self.log(f"loaded {filename} ({path.stat().st_size} bytes)")
        with open(path) as f:
            return json.load(f)

    def write_json(self, filename: str, data: Any):
        self.data_dir.mkdir(parents=True, exist_ok=True)
        with open(self.data_dir / filename, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")

    # ── Env-var expansion for secret interpolation ────

    @staticmethod
    def expand_env(value: Any) -> Any:
        """Replace ${VAR} placeholders in strings with environment values.

        Walks dicts/lists recursively. Non-string leaves pass through unchanged.
        Missing env vars expand to empty string (matches shell behavior).
        """
        import re

        pattern = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")

        def sub(v: Any) -> Any:
            if isinstance(v, str):
                return pattern.sub(lambda m: os.environ.get(m.group(1), ""), v)
            if isinstance(v, dict):
                return {k: sub(x) for k, x in v.items()}
            if isinstance(v, list):
                return [sub(x) for x in v]
            return v

        return sub(value)

    # ── Destructive-write reconciliation ──────────────
    #
    # For services whose write API replaces the entire config on each call
    # (e.g. NZBget's saveconfig JSON-RPC), sending a partial payload silently
    # deletes every other key. Subclasses override fetch_config and
    # write_config, then call reconcile_destructive(desired) to apply the
    # merge-before-write invariant.
    #
    # This is the merge-before-write invariant of the config-sync design.

    SENSITIVE_KEY_PATTERNS = ("password", "secret", "token", "apikey", "api_key")

    def fetch_config(self) -> dict:
        """Return the service's current config as a flat {str: str} dict.

        Override in subclasses that use reconcile_destructive().
        """
        raise NotImplementedError

    def write_config(self, full_config: dict) -> None:
        """Write the complete merged config back to the service.

        Override in subclasses that use reconcile_destructive().
        """
        raise NotImplementedError

    def _is_sensitive(self, key: str) -> bool:
        k = key.lower()
        return any(p in k for p in self.SENSITIVE_KEY_PATTERNS)

    def reconcile_destructive(self, desired: dict) -> dict:
        """Merge desired onto live config and write full set back.

        Returns the set of keys whose values changed (empty set = no-op).
        In diff mode, logs what would change without writing.
        """
        current = self.fetch_config()
        changed = {k: v for k, v in desired.items() if str(current.get(k, "")) != str(v)}
        if not changed:
            self.log("config in sync")
            return set()

        for k, new in changed.items():
            old = current.get(k, "")
            if self._is_sensitive(k):
                self.log(f"{k}: *** -> *** (changed)")
            else:
                self.log(f"{k}: {old!r} -> {new!r}")

        if self.mode == "diff":
            self.log(f"would write {len(current | changed)} keys ({len(changed)} changed)")
            return set(changed.keys())

        merged = {**current, **changed}
        self.write_config(merged)
        self.log(f"wrote {len(merged)} keys ({len(changed)} changed)")
        return set(changed.keys())

    # ── Interface (override these) ────────────────────

    def sync(self):
        """Push data/ JSON → app APIs. Check self.mode for 'sync' vs 'diff'."""
        raise NotImplementedError

    def export(self):
        """Pull app APIs → data/ JSON files."""
        raise NotImplementedError


# ── Module discovery ────────────────────────────────────
# Shared by sync.py and export.py so the discovery rule (auto-discover every
# AppModule subclass in configs/sync/modules/, dedup by .name) lives in one
# place. pkgutil walks the package lazily here to avoid a circular import:
# base.py is imported by every module, so importing the package at module load
# would re-enter base.py before AppModule is defined.


def discover_modules(data_dir: pathlib.Path, mode: str) -> list[AppModule]:
    """Import all modules in configs.sync.modules and instantiate AppModule subclasses.

    Drop a .py file in configs/sync/modules/ that subclasses AppModule and it is
    picked up with no registration. The first definition of each name wins.
    """
    import importlib
    import pkgutil

    import configs.sync.modules as pkg

    modules: list[AppModule] = []
    for _importer, modname, _ispkg in pkgutil.iter_modules(pkg.__path__):
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
