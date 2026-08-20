"""Prowlarr config sync module.

Manages indexers and host config via the Prowlarr REST API (/api/v1/).
Prowlarr is an *arr app but uses v1 (not v3 like Radarr/Sonarr).

Secret handling:
- Host apiKey is exported as ${PROWLARR_API_KEY}. On sync, expand_env()
  fills it from the environment — enables key rotation + fresh deploys.
- Indexer secret fields (by name, or any field whose schema `privacy` is
  not "normal") are exported as <REDACTED>. On sync, fields are merged by
  name and sentinel values (<REDACTED>, ********) are never sent — the live
  value is kept on update; on create the field is left for manual entry.
- Other host secrets (password, proxyPassword) are <REDACTED> and preserved
  via merge-before-write.
"""

import copy

from configs.sync.base import REDACTED, AppModule, is_secret_sentinel

HOST_SECRET_KEYS = frozenset(
    {"apiKey", "password", "passwordConfirmation", "proxyPassword", "sslCertPassword"}
)

# Host config keys exported as ${VAR} placeholders (flow from .env on deploy).
# If the env var is unset, falls back to <REDACTED> (preserves live value).
HOST_SECRET_ENV_MAPPING = {
    "apiKey": "PROWLARR_API_KEY",
}

# Indexer fields that are secrets regardless of what the definition's
# `privacy` attribute says (compared case-insensitively).
INDEXER_SECRET_FIELD_NAMES = frozenset(
    {"apikey", "api_key", "password", "passkey", "cookie", "token", "username", "uid"}
)


def _is_secret_field(field: dict) -> bool:
    name = str(field.get("name", "")).lower()
    return name in INDEXER_SECRET_FIELD_NAMES or field.get("privacy", "normal") != "normal"


class ProwlarrModule(AppModule):
    name = "prowlarr"
    url_env = "PROWLARR_URL"
    key_env = "PROWLARR_API_KEY"
    default_url = "http://prowlarr:9696"
    expected_files = ["indexers.json", "host-config.json"]
    api_prefix = "api/v1"  # Prowlarr is v1, not v3

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
                [
                    {
                        "name": f["name"],
                        "value": REDACTED if (_is_secret_field(f) and f.get("value")) else f.get("value"),
                    }
                    for f in fields
                ],
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
        self.run_steps([
            ("indexers", self._sync_indexers),
            ("host config", self._sync_host_config),
        ])

    @staticmethod
    def _normalize_sentinels(di: dict) -> dict:
        """Map any secret sentinel in desired fields to REDACTED for comparison."""
        out = dict(di)
        if "fields" in out:
            out["fields"] = [
                {**f, "value": REDACTED if is_secret_sentinel(f.get("value")) else f.get("value")}
                for f in out["fields"]
            ]
        return out

    @staticmethod
    def _merge_fields(base_fields: list, desired_fields: list) -> list:
        """Overlay desired [{name,value}] onto base fields BY NAME.

        Sentinel values are never applied: the base (remote) value is kept.
        """
        merged = copy.deepcopy(base_fields)
        by_name = {f["name"]: f for f in merged}
        for df in desired_fields:
            name = df["name"]
            if is_secret_sentinel(df.get("value")):
                continue
            if name in by_name:
                by_name[name]["value"] = df.get("value")
            else:
                merged.append({"name": name, "value": df.get("value")})
        return merged

    def _sync_indexers(self):
        desired = self.load_json("indexers.json")
        if desired is None:
            return

        remote = self.api_get("indexer")
        remote_by_name = {idx["name"]: idx for idx in remote}
        schemas = None  # lazy-fetched on first create (large payload)
        changes = 0

        for di in desired:
            name = di["name"]
            if name in remote_by_name:
                remote_idx = remote_by_name[name]
                if self._strip_indexer(remote_idx) != self._normalize_sentinels(di):
                    if self.mode == "diff":
                        self.log(f"indexer '{name}': would update")
                    else:
                        merged = copy.deepcopy(remote_idx)
                        merged.update({k: v for k, v in di.items() if k != "fields"})
                        merged["fields"] = self._merge_fields(
                            remote_idx.get("fields", []), di.get("fields", [])
                        )
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
                    if schemas is None:
                        schemas = self.api_get("indexer/schema") or []
                    template = next(
                        (s for s in schemas if s.get("implementation") == di.get("implementation")),
                        None,
                    )
                    if template is None:
                        self.log(
                            f"WARNING: no schema for implementation '{di.get('implementation')}' — skipping '{name}'"
                        )
                        continue
                    masked = sorted(
                        f["name"] for f in di.get("fields", [])
                        if is_secret_sentinel(f.get("value")) or self.has_placeholder(f.get("value"))
                    )
                    if masked:
                        # See radarr: a create without its secret fails
                        # Prowlarr's test-on-save, so skip rather than 400 forever.
                        self.log(
                            f"WARNING: cannot create indexer '{name}': secret field "
                            f"'{masked[0]}' is masked in indexers.json — create it once in "
                            "the UI with this exact name (or set a ${VAR} placeholder), after "
                            "which sync will manage it"
                        )
                        continue
                    new_idx = copy.deepcopy(template)
                    new_idx.pop("id", None)
                    new_idx.update({k: v for k, v in di.items() if k != "fields"})
                    new_idx["fields"] = self._merge_fields(
                        template.get("fields", []), di.get("fields", [])
                    )
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

        # Expand ${VAR} placeholders; unresolved ones become <REDACTED> and
        # are skipped below so the live value is preserved.
        desired = self.expand_env_or_redact(desired)

        remote = self.api_get("config/host")
        remote_stripped = {k: v for k, v in remote.items() if k != "id"}

        changed = {}
        for k, v in desired.items():
            if v == REDACTED:
                continue
            if remote_stripped.get(k) != v:
                if self.mode == "diff":
                    shown = "***" if k in HOST_SECRET_KEYS else repr(v)
                    self.log(f"host config: {k} {remote_stripped.get(k)!r} -> {shown}")
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
