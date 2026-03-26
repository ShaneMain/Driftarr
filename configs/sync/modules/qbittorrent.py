"""qBittorrent config sync module.

Exports and imports application preferences via the WebAPI v2.
No auth needed — subnet whitelist bypasses login (behind Gluetun VPN).
Categories/tags/seeding rules are managed by qbit_manage, not this module.
"""

import json
import time
import urllib.error
import urllib.request

from configs.sync.base import AppModule

# Keys that are read-only, instance-specific, or security-sensitive.
# These are stripped on export and ignored during sync.
EXCLUDED_KEYS = frozenset({
    # Credentials / auth
    "web_ui_username",
    "web_ui_password",
    # SSL cert paths (instance-specific)
    "web_ui_https_cert_path",
    "web_ui_https_key_path",
    # Instance-specific network interface bindings
    "current_interface_address",
    "current_interface_name",
    "current_network_interface",
    # Listen port (assigned by Gluetun VPN)
    "listen_port",
    "random_port",
    # Proxy credentials (in .env / Gluetun, not qBit)
    "proxy_password",
    "proxy_username",
    # DynDNS credentials
    "dyndns_password",
    "dyndns_username",
    # Mail notification credentials
    "mail_notification_password",
    "mail_notification_username",
    # Paths that vary per instance
    "save_path",
    "temp_path",
    "export_dir",
    "export_dir_fin",
    "file_log_path",
    "python_executable_path",
    "ip_filter_path",
    # Scan dirs (dict of path→mode, instance-specific)
    "scan_dirs",
})


class QbittorrentModule(AppModule):
    name = "qbittorrent"
    url_env = "QBITTORRENT_URL"
    key_env = ""  # No API key — auth bypassed via subnet whitelist
    default_url = "http://qbittorrent:8080"
    expected_files = ["preferences.json"]

    # ── API helpers (v2, no auth) ─────────────────────

    def _qbit_get(self, endpoint: str):
        req = urllib.request.Request(
            f"{self.url}/api/v2/{endpoint}",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            if not raw:
                return None
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return raw.decode()  # plain text (e.g. version string)

    def _qbit_post_prefs(self, prefs: dict):
        """POST changed preferences. qBit expects form-encoded json= field."""
        body = f"json={json.dumps(prefs)}".encode()
        req = urllib.request.Request(
            f"{self.url}/api/v2/app/setPreferences",
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()

    # ── Health ────────────────────────────────────────

    def wait_until_ready(self, timeout: int = 60) -> bool:
        self.log("waiting for qbittorrent...")
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self._qbit_get("app/version")
                self.log("qbittorrent ready")
                return True
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(1)
        self.log(f"ERROR: qbittorrent not ready after {timeout}s")
        return False

    def is_reachable(self) -> bool:
        try:
            self._qbit_get("app/version")
            return True
        except (urllib.error.URLError, OSError):
            self.log(f"ERROR: not reachable at {self.url}")
            return False

    # ── Export ────────────────────────────────────────

    def export(self):
        prefs = self._qbit_get("app/preferences")
        filtered = {
            k: v for k, v in sorted(prefs.items())
            if k not in EXCLUDED_KEYS
        }
        self.write_json("preferences.json", filtered)
        self.log(f"exported {len(filtered)} preferences ({len(prefs) - len(filtered)} excluded)")

    # ── Sync ──────────────────────────────────────────

    def sync(self):
        desired = self.load_json("preferences.json")
        if desired is None:
            self.log("no preferences.json found, skipping")
            return

        live = self._qbit_get("app/preferences")
        diff = {}
        for key, want in desired.items():
            if key in EXCLUDED_KEYS:
                continue
            if live.get(key) != want:
                diff[key] = want

        if not diff:
            self.log("preferences: in sync")
            return

        if self.mode == "diff":
            for key, want in sorted(diff.items()):
                self.log(f"  {key}: {live.get(key)!r} -> {want!r}")
            self.log(f"preferences: {len(diff)} would change")
        else:
            self._qbit_post_prefs(diff)
            self.log(f"preferences: applied {len(diff)} changes")
