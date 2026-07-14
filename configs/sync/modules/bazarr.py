"""Bazarr config sync module.

Manages subtitle settings (48 sections) and language profiles via the
Bazarr REST API (/api/). Settings are exported with secrets redacted;
on sync, current live secrets are preserved via merge-before-write.

Language profiles are export-only — Bazarr 1.x exposes no write API
(POST/PATCH/DELETE return 405). They are captured for visibility but
cannot be pushed.
"""

import copy
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

from configs.sync.base import AppModule

REDACTED = "<REDACTED>"

SECRET_KEY_PATTERNS = (
    "password",
    "token",
    "apikey",
    "api_key",
    "api_client",
    "cookies",
    "hashed_password",
    "secret",
)


def _is_secret_key(key: str) -> bool:
    k = key.lower()
    return any(p in k for p in SECRET_KEY_PATTERNS)


class BazarrModule(AppModule):
    name = "bazarr"
    url_env = "BAZARR_URL"
    key_env = "BAZARR_API_KEY"
    default_url = "http://bazarr:6767"
    expected_files = ["settings.json"]

    # ── API helpers (Bazarr uses /api/, not /api/v3/) ──

    def api_get(self, endpoint: str):
        return self._request(f"{self.url}/api/{endpoint}")

    def api_post(self, endpoint: str, data):
        return self._request(f"{self.url}/api/{endpoint}", "POST", data)

    # ── Health (override — Bazarr uses /api/system/status) ──

    def wait_until_ready(self, timeout: int = 60) -> bool:
        if not self.api_key:
            self.log(f"no API key configured ({self.key_env}), skipping")
            return False

        import socket

        parsed = urlparse(self.url)
        host = parsed.hostname
        port = parsed.port or 80

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
                    f"{self.url}/api/system/status",
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
                f"{self.url}/api/system/status",
                headers=self._headers(),
            )
            with urllib.request.urlopen(req, timeout=5):
                return True
        except (urllib.error.URLError, OSError):
            self.log(f"ERROR: not reachable at {self.url}")
            return False

    # ── Secret redaction ──────────────────────────────

    @staticmethod
    def _redact(obj):
        """Recursively replace secret values with REDACTED."""
        if isinstance(obj, dict):
            return {
                k: REDACTED if (_is_secret_key(k) and v) else BazarrModule._redact(v)
                for k, v in obj.items()
            }
        if isinstance(obj, list):
            return [BazarrModule._redact(x) for x in obj]
        return obj

    @staticmethod
    def _merge_keeping_secrets(current, desired):
        """Deep-merge desired onto current, skipping REDACTED placeholders."""
        if isinstance(current, dict) and isinstance(desired, dict):
            result = copy.deepcopy(current)
            for k, v in desired.items():
                if isinstance(v, dict) and isinstance(result.get(k), dict):
                    result[k] = BazarrModule._merge_keeping_secrets(result[k], v)
                elif v == REDACTED:
                    pass  # preserve current secret
                else:
                    result[k] = v
            return result
        return desired

    # ── Export ────────────────────────────────────────

    def export(self):
        self._export_settings()
        self._export_language_profiles()

    def _export_settings(self):
        raw = self.api_get("system/settings")

        # Sort notifications providers list for deterministic output
        notifications = raw.get("notifications", {})
        if isinstance(notifications.get("providers"), list):
            notifications["providers"] = sorted(
                notifications["providers"], key=lambda x: x.get("name", "")
            )

        # Sort list-valued keys in general for deterministic output
        general = raw.get("general", {})
        for list_key in ("enabled_providers", "enabled_integrations"):
            if isinstance(general.get(list_key), list):
                general[list_key] = sorted(general[list_key])

        redacted = self._redact(raw)
        self.write_json("settings.json", redacted)
        self.log(f"exported {len(redacted)} settings sections")

    def _export_language_profiles(self):
        raw = self.api_get("system/languages/profiles")
        if not isinstance(raw, list):
            return

        exported = sorted(
            [
                {
                    "name": p.get("name", ""),
                    "cutoff": p.get("cutoff"),
                    "items": [
                        {
                            "language": item.get("language"),
                            "audio_exclude": item.get("audio_exclude"),
                            "hi": item.get("hi"),
                            "forced": item.get("forced"),
                            "audio_only_include": item.get("audio_only_include"),
                        }
                        for item in p.get("items", [])
                    ],
                    "mustContain": p.get("mustContain", []),
                    "mustNotContain": p.get("mustNotContain", []),
                    "originalFormat": p.get("originalFormat"),
                    "tag": p.get("tag"),
                }
                for p in raw
            ],
            key=lambda x: x["name"],
        )
        self.write_json("language-profiles.json", exported)
        self.log(f"exported {len(exported)} language profiles")

    # ── Sync ──────────────────────────────────────────

    def sync(self):
        self._sync_settings()

    def _sync_settings(self):
        desired = self.load_json("settings.json")
        if desired is None:
            if self.is_bootstrap_mode():
                self.log("BOOTSTRAP: no settings exported yet — skipping sync (run export first)")
                return
            desired = {}

        if not self.wait_until_ready():
            return

        current = self.api_get("system/settings")
        merged = self._merge_keeping_secrets(current, desired)

        # Compute which sections actually changed
        changed_sections = {}
        for section in desired:
            if merged.get(section) != current.get(section):
                changed_sections[section] = merged[section]

        if not changed_sections:
            self.log("settings: in sync")
            return

        if self.mode == "diff":
            self.log(f"would update sections: {sorted(changed_sections.keys())}")
            return

        self.api_post("system/settings", changed_sections)
        self.log(f"updated {len(changed_sections)} sections: {sorted(changed_sections.keys())}")
