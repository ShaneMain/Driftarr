"""Bazarr config sync module.

Manages subtitle settings (48 sections) and language profiles via the
Bazarr REST API (/api/).

Secret handling:
- Known integration keys (Sonarr, Radarr, Bazarr API keys) are exported
  as ${VAR} placeholders. On sync, expand_env() replaces them with values
  from the environment (.env). This enables key rotation and fresh deploys:
  change the key in .env, deploy, and all referencing services get updated.
- Other secrets (provider cookies, Plex tokens) are exported as <REDACTED>.
  On sync, merge-before-write preserves the live value. These can't be
  rotated via .env (no env var maps to them).

Language profiles are export-only — Bazarr 1.x exposes no write API
(POST/PATCH/DELETE return 405). They are captured for visibility but
cannot be pushed.
"""

import copy
import json
import urllib.request
from urllib.parse import urlencode

from configs.sync.base import REDACTED, AppModule

SECRET_KEY_PATTERNS = (
    "password",
    "token",
    "apikey",
    "api_key",
    "api_client",
    "cookies",
    "hashed_password",
    "secret",
    "passkey",
    "encryption",
    "captcha",
    "gemini_key",
)

# Maps (section, key) → env var name. On export, these secrets are written
# as ${VAR} placeholders instead of <REDACTED>. On sync, expand_env() fills
# them from the environment. If the env var is unset, falls back to <REDACTED>
# (preserves the live value via merge-before-write).
SECRET_ENV_MAPPING = {
    ("auth", "apikey"): "BAZARR_API_KEY",
    ("sonarr", "apikey"): "SONARR_API_KEY",
    ("radarr", "apikey"): "RADARR_API_KEY",
}


def _is_secret_key(key: str) -> bool:
    k = key.lower()
    return any(p in k for p in SECRET_KEY_PATTERNS)


class BazarrModule(AppModule):
    name = "bazarr"
    url_env = "BAZARR_URL"
    key_env = "BAZARR_API_KEY"
    default_url = "http://bazarr:6767"
    expected_files = ["settings.json"]
    api_prefix = "api"  # Bazarr is /api/, not /api/v3/

    def _post_settings_form(self, changed_sections: dict):
        """POST settings as form-encoded data.

        Bazarr's POST /api/system/settings reads request.form (NOT JSON).
        Field names follow: settings-{section}-{key}. Booleans become
        "true"/"false" strings. Lists become repeated fields. Notifications
        use a separate notifications-providers field with JSON values.
        """
        form_fields = []
        for section, fields in changed_sections.items():
            if not isinstance(fields, dict):
                continue
            if section == "notifications":
                # Notifications use a dedicated form field with JSON values
                for provider in fields.get("providers", []):
                    form_fields.append(("notifications-providers", json.dumps(provider)))
                continue
            for key, value in fields.items():
                form_key = f"settings-{section}-{key}"
                if isinstance(value, bool):
                    form_fields.append((form_key, "true" if value else "false"))
                elif isinstance(value, list):
                    for item in value:
                        form_fields.append((form_key, str(item)))
                elif value is None:
                    form_fields.append((form_key, ""))
                else:
                    form_fields.append((form_key, str(value)))

        body = urlencode(form_fields).encode()
        req = urllib.request.Request(
            f"{self.url}/api/system/settings",
            data=body,
            headers={
                "X-Api-Key": self.api_key,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()

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

        # Replace <REDACTED> with ${VAR} for mapped integration keys.
        # These flow from .env on deploy — enables key rotation + fresh deploys.
        for (section, key), env_var in SECRET_ENV_MAPPING.items():
            sec = redacted.get(section)
            if isinstance(sec, dict) and sec.get(key) == REDACTED:
                sec[key] = f"${{{env_var}}}"

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
            return

        # Expand ${VAR} placeholders; unresolved ones become <REDACTED> so
        # merge-before-write preserves the live secret.
        desired = self.expand_env_or_redact(desired)

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

        self._post_settings_form(changed_sections)
        self.log(f"updated {len(changed_sections)} sections: {sorted(changed_sections.keys())}")
