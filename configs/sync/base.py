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
    name: str = ""           # e.g. "radarr" — also the data subdirectory name
    url_env: str = ""        # env var for URL, e.g. "RADARR_URL"
    key_env: str = ""        # env var for API key, e.g. "RADARR_API_KEY"
    default_url: str = ""    # fallback URL if env var not set
    config_xml_path: str = ""  # optional: path to config.xml for API key

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
            json.dump(data, f, indent=2)
            f.write("\n")

    # ── Interface (override these) ────────────────────

    def sync(self):
        """Push data/ JSON → app APIs. Check self.mode for 'sync' vs 'diff'."""
        raise NotImplementedError

    def export(self):
        """Pull app APIs → data/ JSON files."""
        raise NotImplementedError
