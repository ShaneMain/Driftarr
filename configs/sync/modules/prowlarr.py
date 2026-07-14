"""Prowlarr config sync module.

Manages indexers and host config via the Prowlarr REST API (/api/v1/).
Prowlarr is an *arr app but uses v1 (not v3 like Radarr/Sonarr).

Secret handling:
- Host apiKey is exported as ${PROWLARR_API_KEY}. On sync, expand_env()
  fills it from the environment — enables key rotation + fresh deploys.
- Indexer secrets (cookies, API keys) are masked as '********' by Prowlarr's
  API — kept as-is on export, ignored on sync (standard *arr behavior).
- Other host secrets (password, proxyPassword) are <REDACTED> and preserved
  via merge-before-write.
"""

import copy
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

from configs.sync.base import AppModule

REDACTED = "<REDACTED>"

HOST_SECRET_KEYS = frozenset(
    {"apiKey", "password", "passwordConfirmation", "proxyPassword", "sslCertPassword"}
)

# Host config keys exported as ${VAR} placeholders (flow from .env on deploy).
# If the env var is unset, falls back to <REDACTED> (preserves live value).
HOST_SECRET_ENV_MAPPING = {
    "apiKey": "PROWLARR_API_KEY",
}

# Fields stripped from indexer exports (volatile / read-only / huge)
INDEXER_VOLATILE_FIELDS = frozenset(
    {
        "capabilities",
        "id",
        "sortName",
        "encoding",
        "language",
        "clamp",
        "lastFailure",
        "disabledUntil",
        "status",
        "initialState",
        "priority",
        "protocol",
        "privacy",
        "supportsRss",
        "supportsSearch",
        "supportsRedirect",
        "downloadClientId",
        "redirect",
        "tags",
        "fieldsOrder",
    }
)

# Indexer fields that are secrets (masked as ******** by Prowlarr)
INDEXER_SECRET_FIELD_NAMES = frozenset(
    {"apiKey", "api_key", "password", "passkey", "cookie", "token", "username", "uid"}
)


class ProwlarrModule(AppModule):
    name = "prowlarr"
    url_env = "PROWLARR_URL"
    key_env = "PROWLARR_API_KEY"
    default_url = "http://prowlarr:9696"
    expected_files = ["indexers.json", "host-config.json"]

    # ── API helpers (Prowlarr uses /api/v1/, not /api/v3/) ──

    def api_get(self, endpoint: str):
        return self._request(f"{self.url}/api/v1/{endpoint}")

    def api_put(self, endpoint: str, data):
        return self._request(f"{self.url}/api/v1/{endpoint}", "PUT", data)

    def api_post(self, endpoint: str, data):
        return self._request(f"{self.url}/api/v1/{endpoint}", "POST", data)

    def api_delete(self, endpoint: str):
        self._request(f"{self.url}/api/v1/{endpoint}", "DELETE")

    # ── Health (override — Prowlarr uses /api/v1/system/status) ──

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
                    f"{self.url}/api/v1/system/status",
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
                f"{self.url}/api/v1/system/status",
                headers=self._headers(),
            )
            with urllib.request.urlopen(req, timeout=5):
                return True
        except (urllib.error.URLError, OSError):
            self.log(f"ERROR: not reachable at {self.url}")
            return False

    # ── Export ────────────────────────────────────────

    def export(self):
        self._export_indexers()
        self._export_host_config()

    def _strip_indexer(self, idx: dict) -> dict:
        """Extract stable, comparable fields from an indexer."""
        result = {
            "name": idx.get("name", ""),
            "implementation": idx.get("implementation", ""),
            "enable": idx.get("enable", True),
            "priority": idx.get("priority", 25),
            "appProfileId": idx.get("appProfileId", 1),
        }

        fields = idx.get("fields", [])
        if fields:
            stripped_fields = sorted(
                [{"name": f["name"], "value": f.get("value")} for f in fields],
                key=lambda x: x["name"],
            )
            result["fields"] = stripped_fields

        return result

    def _export_indexers(self):
        raw = self.api_get("indexer")
        exported = sorted(
            [self._strip_indexer(idx) for idx in raw],
            key=lambda x: x["name"],
        )
        self.write_json("indexers.json", exported)
        self.log(f"exported {len(exported)} indexers")

    def _export_host_config(self):
        raw = self.api_get("config/host")
        exported = {k: v for k, v in raw.items() if k != "id"}
        for k in HOST_SECRET_KEYS:
            if k in exported and exported[k]:
                env_var = HOST_SECRET_ENV_MAPPING.get(k)
                exported[k] = f"${{{env_var}}}" if env_var else REDACTED
        self.write_json("host-config.json", exported)
        self.log("exported host config")

    # ── Sync ──────────────────────────────────────────

    def sync(self):
        self._sync_indexers()
        self._sync_host_config()

    def _sync_indexers(self):
        desired = self.load_json("indexers.json")
        if desired is None:
            if self.is_bootstrap_mode():
                self.log("BOOTSTRAP: no indexers exported yet — skipping sync (run export first)")
                return
            desired = []

        remote = self.api_get("indexer")
        remote_by_name = {idx["name"]: idx for idx in remote}
        changes = 0

        for di in desired:
            name = di["name"]
            if name in remote_by_name:
                remote_idx = remote_by_name[name]
                if self._strip_indexer(remote_idx) != di:
                    if self.mode == "diff":
                        self.log(f"indexer '{name}': would update")
                    else:
                        merged = copy.deepcopy(remote_idx)
                        merged.update(di)
                        merged["id"] = remote_idx["id"]
                        self.api_put(f"indexer/{remote_idx['id']}", merged)
                        self.log(f"indexer '{name}': updated")
                    changes += 1
                else:
                    self.log(f"indexer '{name}': in sync")
            else:
                if self.mode == "diff":
                    self.log(f"indexer '{name}': would create")
                else:
                    schemas = self.api_get("indexer/schema")
                    template = next(
                        (s for s in schemas if s.get("implementation") == di.get("implementation")),
                        None,
                    )
                    if template is None:
                        self.log(
                            f"WARNING: no schema for implementation '{di.get('implementation')}' — skipping '{name}'"
                        )
                        continue
                    new_idx = copy.deepcopy(template)
                    new_idx.pop("id", None)
                    new_idx.update(di)
                    self.api_post("indexer", new_idx)
                    self.log(f"indexer '{name}': created")
                changes += 1

        desired_names = {di["name"] for di in desired}
        for ri in remote:
            if ri["name"] not in desired_names:
                if self.mode == "diff":
                    self.log(f"indexer '{ri['name']}': would delete")
                else:
                    self.api_delete(f"indexer/{ri['id']}")
                    self.log(f"indexer '{ri['name']}': deleted")
                changes += 1

        if changes == 0:
            self.log("indexers: all in sync")

    def _sync_host_config(self):
        desired = self.load_json("host-config.json")
        if desired is None:
            return

        # Expand ${VAR} placeholders from the environment.
        # Unset env vars expand to "" — convert back to <REDACTED>.
        desired = self.expand_env(desired)
        for k, _env in HOST_SECRET_ENV_MAPPING.items():
            if desired.get(k) == "":
                desired[k] = REDACTED

        remote = self.api_get("config/host")
        remote_stripped = {k: v for k, v in remote.items() if k != "id"}

        changed = {}
        for k, v in desired.items():
            if v == REDACTED:
                continue
            if remote_stripped.get(k) != v:
                if self.mode == "diff":
                    self.log(f"host config: {k} {remote_stripped.get(k)!r} -> {v!r}")
                else:
                    changed[k] = v

        if not changed:
            self.log("host config: in sync")
            return

        if self.mode == "diff":
            self.log(f"host config: {len(changed)} would change")
            return

        update = {k: remote[k] for k in remote}
        update.update(changed)
        update["id"] = remote["id"]
        self.api_put("config/host", update)
        self.log(f"host config: updated {len(changed)} keys")
