"""Radarr config sync module.

Handles: custom formats, profile scores, quality definitions,
naming, media management, root folders, download client categories.
"""

import copy

from configs.sync.base import AppModule


class RadarrModule(AppModule):
    name = "radarr"
    url_env = "RADARR_URL"
    key_env = "RADARR_API_KEY"
    default_url = "http://radarr:7878"
    config_xml_path = "/radarr-config/config.xml"
    expected_files = [
        "custom-formats.json",
        "profile-scores.json",
        "quality-definitions.json",
        "naming.json",
        "media-management.json",
        "root-folders.json",
        # notifications.json is intentionally NOT required — the module has
        # additive semantics there (see _sync_notifications) and a missing
        # file is the "nothing declared" signal, not bootstrap.
    ]

    # Download client post-import category field + value
    import_category_field = "movieImportedCategory"
    import_category_value = "movies-imported"

    # ── Export ────────────────────────────────────────

    def export(self):
        self._export_custom_formats()
        self._export_profile_scores()
        self._export_quality_definitions()
        self._export_naming()
        self._export_media_management()
        self._export_root_folders()
        self._export_notifications()

    def _export_custom_formats(self):
        raw = self.api_get("customformat")
        exported = sorted([self._strip_cf(cf) for cf in raw], key=lambda x: x["name"])
        self.write_json("custom-formats.json", exported)
        self.log(f"exported {len(exported)} custom formats")

    def _export_profile_scores(self):
        profiles = self.api_get("qualityprofile")
        exported = {}
        for p in profiles:
            entry = {
                "minFormatScore": p.get("minFormatScore", 0),
                "cutoffFormatScore": p.get("cutoffFormatScore", 0),
            }
            entry["formatScores"] = {
                fi["name"]: fi["score"]
                for fi in p.get("formatItems", [])
                if fi.get("score", 0) != 0
            }
            exported[p["name"]] = entry
        self.write_json("profile-scores.json", exported)
        self.log(f"exported {len(exported)} profiles")

    def _export_quality_definitions(self):
        raw = self.api_get("qualitydefinition")
        exported = sorted(
            [
                {
                    "title": qd["title"],
                    "minSize": qd.get("minSize", 0),
                    "maxSize": qd.get("maxSize"),
                    "preferredSize": qd.get("preferredSize"),
                }
                for qd in raw
            ],
            key=lambda x: x["title"],
        )
        self.write_json("quality-definitions.json", exported)
        self.log(f"exported {len(exported)} quality definitions")

    def _export_naming(self):
        raw = self.api_get("config/naming")
        raw.pop("id", None)
        self.write_json("naming.json", raw)
        self.log("exported naming config")

    def _export_media_management(self):
        raw = self.api_get("config/mediamanagement")
        raw.pop("id", None)
        self.write_json("media-management.json", raw)
        self.log("exported media management config")

    def _export_root_folders(self):
        raw = self.api_get("rootfolder")
        exported = sorted([{"path": rf["path"]} for rf in raw], key=lambda x: x["path"])
        self.write_json("root-folders.json", exported)
        self.log(f"exported {len(exported)} root folders")

    # Event-toggle keys in *arr notification payloads. Present/absent set varies
    # by app (Sonarr vs Radarr) and version — handle them generically by prefix.
    _TOGGLE_PREFIX = "on"

    def _notification_toggles(self, entry: dict) -> dict:
        """Return only the on*/includeHealthWarnings keys from a notification."""
        out = {}
        for k, v in entry.items():
            if k.startswith(self._TOGGLE_PREFIX) and isinstance(v, bool):
                out[k] = v
            elif k == "includeHealthWarnings" and isinstance(v, bool):
                out[k] = v
        return out

    def _export_notifications(self):
        raw = self.api_get("notification")
        exported = []
        for n in sorted(raw, key=lambda x: x["name"]):
            entry = {
                "name": n["name"],
                "implementation": n["implementation"],
            }
            # Export event toggles that are True. Ignoring False keeps diffs small
            # across Sonarr/Radarr versions that add new toggle keys over time.
            for k, v in self._notification_toggles(n).items():
                if v:
                    entry[k] = True
            fields = sorted(
                [
                    {"name": f["name"], "value": f["value"]}
                    for f in n.get("fields", [])
                    if f.get("value") not in (None, "", [], {})
                ],
                key=lambda x: x["name"],
            )
            if fields:
                entry["fields"] = fields
            if n.get("tags"):
                entry["tags"] = n["tags"]
            exported.append(entry)
        self.write_json("notifications.json", exported)
        self.log(f"exported {len(exported)} notifications")

    # ── Sync ──────────────────────────────────────────

    def sync(self):
        self._sync_custom_formats()
        self._sync_profile_scores()
        self._sync_quality_definitions()
        self._sync_naming()
        self._sync_media_management()
        self._sync_root_folders()
        self._sync_download_clients()
        self._sync_notifications()

    def _strip_cf(self, cf):
        return {
            "name": cf["name"],
            "includeCustomFormatWhenRenaming": cf.get("includeCustomFormatWhenRenaming", False),
            "specifications": sorted(
                [
                    {
                        "name": s["name"],
                        "implementation": s["implementation"],
                        "negate": s["negate"],
                        "required": s["required"],
                        "fields": sorted(
                            [{"name": f["name"], "value": f["value"]} for f in s["fields"]],
                            key=lambda x: x["name"],
                        ),
                    }
                    for s in cf.get("specifications", [])
                ],
                key=lambda x: x["name"],
            ),
        }

    def _sync_custom_formats(self):
        desired = self.load_json("custom-formats.json")
        if desired is None:
            if self.is_bootstrap_mode():
                self.log("BOOTSTRAP: no configs exported yet — skipping sync (run export first)")
                return
            desired = []  # Missing file = delete all from API

        remote_cfs = self.api_get("customformat")
        remote_by_name = {cf["name"]: cf for cf in remote_cfs}
        changes = 0

        for dcf in desired:
            cf_name = dcf["name"]
            if cf_name in remote_by_name:
                remote = remote_by_name[cf_name]
                if self._strip_cf(remote) != self._strip_cf(dcf):
                    if self.mode == "diff":
                        self.log(f"CF: would update '{cf_name}'")
                    else:
                        dcf["id"] = remote["id"]
                        self.api_put(f"customformat/{remote['id']}", dcf)
                        self.log(f"CF: updated '{cf_name}'")
                    changes += 1
            else:
                if self.mode == "diff":
                    self.log(f"CF: would create '{cf_name}'")
                else:
                    self.api_post("customformat", dcf)
                    self.log(f"CF: created '{cf_name}'")
                changes += 1

        desired_names = {cf["name"] for cf in desired}
        for rcf in remote_cfs:
            if rcf["name"] not in desired_names:
                if self.mode == "diff":
                    self.log(f"CF: would delete '{rcf['name']}'")
                else:
                    self.api_delete(f"customformat/{rcf['id']}")
                    self.log(f"CF: deleted '{rcf['name']}'")

        if changes == 0:
            self.log("custom formats: in sync")

    def _clone_profile_template(self, profiles):
        """Deep-clone the first existing profile as a template for new profiles."""
        if not profiles:
            return None
        template = copy.deepcopy(profiles[0])
        template.pop("id", None)
        template["name"] = ""
        template["minFormatScore"] = 0
        template["cutoffFormatScore"] = 0
        for fi in template.get("formatItems", []):
            fi["score"] = 0
        return template

    def _sync_profile_scores(self):
        desired = self.load_json("profile-scores.json")
        if desired is None:
            if self.is_bootstrap_mode():
                self.log("BOOTSTRAP: no configs exported yet — skipping sync (run export first)")
                return
            desired = {}  # Missing file = reset all scores / delete extra profiles

        profiles = self.api_get("qualityprofile")
        profiles_by_name = {p["name"]: p for p in profiles}

        for pname, pconfig in desired.items():
            if pname not in profiles_by_name:
                # Create missing profile by cloning an existing one as template
                template = self._clone_profile_template(profiles)
                if template is None:
                    self.log(
                        f"WARNING: profile '{pname}' not found and no existing profiles to use as template — skipping"
                    )
                    continue
                template["name"] = pname
                for field in ("minFormatScore", "cutoffFormatScore"):
                    if field in pconfig:
                        template[field] = pconfig[field]
                scores = pconfig.get("formatScores", {})
                for fi in template.get("formatItems", []):
                    fi["score"] = scores.get(fi["name"], 0)
                if self.mode == "diff":
                    self.log(f"profile '{pname}': would create")
                else:
                    created = self.api_post("qualityprofile", template)
                    self.log(f"profile '{pname}': created (cloned from '{profiles[0]['name']}')")
                    # Add to lookup so deletion pass doesn't remove it
                    profiles_by_name[pname] = created
                continue

            profile = profiles_by_name[pname]
            updated = False

            for field in ("minFormatScore", "cutoffFormatScore"):
                if field in pconfig and pconfig[field] != profile.get(field):
                    if self.mode == "diff":
                        self.log(
                            f"profile '{pname}': {field} {profile.get(field)} -> {pconfig[field]}"
                        )
                    profile[field] = pconfig[field]
                    updated = True

            scores = pconfig.get("formatScores", {})
            for i, fi in enumerate(profile.get("formatItems", [])):
                target = scores.get(fi["name"], 0)
                if fi["score"] != target:
                    if self.mode == "diff":
                        self.log(f"profile '{pname}': {fi['name']} {fi['score']} -> {target}")
                    profile["formatItems"][i]["score"] = target
                    updated = True

            if updated and self.mode != "diff":
                self.api_put(f"qualityprofile/{profile['id']}", profile)
                self.log(f"profile '{pname}': updated")
            elif not updated:
                self.log(f"profile '{pname}': in sync")

        # Delete profiles not in desired JSON
        for profile in profiles:
            if profile["name"] not in desired:
                if self.mode == "diff":
                    self.log(f"profile '{profile['name']}': would delete")
                else:
                    self.api_delete(f"qualityprofile/{profile['id']}")
                    self.log(f"profile '{profile['name']}': deleted")

    def _sync_quality_definitions(self):
        desired = self.load_json("quality-definitions.json")
        if desired is None:
            return

        remote_qds = self.api_get("qualitydefinition")
        remote_by_title = {qd["title"]: qd for qd in remote_qds}
        changes = 0

        for dqd in desired:
            title = dqd["title"]
            if title not in remote_by_title:
                self.log(f"quality '{title}': not found on remote, skipping")
                continue
            remote = remote_by_title[title]
            if any(dqd.get(f) != remote.get(f) for f in ("minSize", "maxSize", "preferredSize")):
                if self.mode == "diff":
                    self.log(
                        f"quality '{title}': min={remote.get('minSize')}→{dqd.get('minSize')} max={remote.get('maxSize')}→{dqd.get('maxSize')} pref={remote.get('preferredSize')}→{dqd.get('preferredSize')}"
                    )
                else:
                    remote.update({k: dqd[k] for k in ("minSize", "maxSize", "preferredSize")})
                    self.api_put(f"qualitydefinition/{remote['id']}", remote)
                    self.log(f"quality '{title}': updated")
                changes += 1

        if changes == 0:
            self.log(f"quality definitions: all {len(desired)} in sync")
        else:
            self.log(f"quality definitions: {changes}/{len(desired)} updated")

    def _sync_naming(self):
        desired = self.load_json("naming.json")
        if desired is None:
            return

        remote = self.api_get("config/naming")
        remote_stripped = {k: v for k, v in remote.items() if k != "id"}

        if remote_stripped != desired:
            if self.mode == "diff":
                self.log("naming: would update")
            else:
                desired["id"] = remote["id"]
                self.api_put(f"config/naming/{remote['id']}", desired)
                self.log("naming: updated")
        else:
            self.log("naming: in sync")

    def _sync_media_management(self):
        desired = self.load_json("media-management.json")
        if desired is None:
            return

        remote = self.api_get("config/mediamanagement")
        remote_stripped = {k: v for k, v in remote.items() if k != "id"}

        if remote_stripped != desired:
            if self.mode == "diff":
                self.log("media management: would update")
            else:
                desired["id"] = remote["id"]
                self.api_put(f"config/mediamanagement/{remote['id']}", desired)
                self.log("media management: updated")
        else:
            self.log("media management: in sync")

    def _sync_root_folders(self):
        desired = self.load_json("root-folders.json")
        if desired is None:
            if self.is_bootstrap_mode():
                self.log("BOOTSTRAP: no configs exported yet — skipping sync (run export first)")
                return
            desired = []  # Missing file = delete all from API

        remote_rfs = self.api_get("rootfolder")
        remote_by_path = {rf["path"]: rf for rf in remote_rfs}
        desired_paths = {drf["path"] for drf in desired}
        changes = 0

        for drf in desired:
            if drf["path"] not in remote_by_path:
                if self.mode == "diff":
                    self.log(f"root folder: would add '{drf['path']}'")
                else:
                    self.api_post("rootfolder", drf)
                    self.log(f"root folder: added '{drf['path']}'")
                changes += 1

        for rrf in remote_rfs:
            if rrf["path"] not in desired_paths:
                if self.mode == "diff":
                    self.log(f"root folder: would delete '{rrf['path']}'")
                else:
                    self.api_delete(f"rootfolder/{rrf['id']}")
                    self.log(f"root folder: deleted '{rrf['path']}'")
                changes += 1

        if changes == 0:
            self.log(f"root folders: all {len(desired)} in sync")
        else:
            self.log(f"root folders: {changes} changed")

    def _sync_notifications(self):
        """Reconcile /api/v3/notification entries against notifications.json.

        Additive semantics: creates/updates entries whose name matches a
        desired entry, leaves other remote notifications alone. Notifications
        are commonly added ad-hoc via the *arr UI (Discord, webhooks, etc.)
        so a declarative-delete would wipe user entries. Declared entries
        *are* reconciled fully — fields and event toggles match the file.

        For create operations, fetches /api/v3/notification/schema and uses
        the template for the target `implementation` so required default
        fields are populated — *arr rejects POSTs that omit schema fields.
        """
        desired = self.load_json("notifications.json")
        if desired is None:
            # Missing file = nothing declared. Do nothing (additive).
            return

        remote = self.api_get("notification") or []
        remote_by_name = {n["name"]: n for n in remote}
        schemas = None  # lazy-fetched on first create

        for dn in desired:
            name = dn["name"]
            impl = dn["implementation"]
            desired_fields = {f["name"]: f["value"] for f in dn.get("fields", [])}
            desired_toggles = self._notification_toggles(dn)

            if name in remote_by_name:
                existing = remote_by_name[name]
                updated = False

                for k, v in desired_toggles.items():
                    if existing.get(k) != v:
                        if self.mode == "diff":
                            self.log(f"notification '{name}': {k} {existing.get(k)} -> {v}")
                        existing[k] = v
                        updated = True
                # Toggles not listed in desired are assumed default-false — if
                # the remote has a stray True we didn't declare, reset it.
                for k, v in self._notification_toggles(existing).items():
                    if v and k not in desired_toggles:
                        if self.mode == "diff":
                            self.log(f"notification '{name}': {k} {v} -> False")
                        existing[k] = False
                        updated = True

                for k, v in desired_fields.items():
                    replaced = False
                    for f in existing.get("fields", []):
                        if f["name"] == k:
                            if f.get("value") != v:
                                if self.mode == "diff":
                                    self.log(
                                        f"notification '{name}': field {k} {f.get('value')!r} -> {v!r}"
                                    )
                                f["value"] = v
                                updated = True
                            replaced = True
                            break
                    if not replaced:
                        if self.mode == "diff":
                            self.log(f"notification '{name}': add field {k}={v!r}")
                        existing.setdefault("fields", []).append({"name": k, "value": v})
                        updated = True

                if updated and self.mode != "diff":
                    self.api_put(f"notification/{existing['id']}", existing)
                    self.log(f"notification '{name}': updated")
                elif not updated:
                    self.log(f"notification '{name}': in sync")
            else:
                if schemas is None:
                    schemas = self.api_get("notification/schema") or []
                template = next(
                    (s for s in schemas if s.get("implementation") == impl),
                    None,
                )
                if template is None:
                    self.log(f"WARNING: no schema for implementation '{impl}' — skipping '{name}'")
                    continue
                new_entry = copy.deepcopy(template)
                new_entry.pop("id", None)
                new_entry["name"] = name
                for k, v in desired_toggles.items():
                    new_entry[k] = v
                for f in new_entry.get("fields", []):
                    if f["name"] in desired_fields:
                        f["value"] = desired_fields[f["name"]]
                new_entry["tags"] = dn.get("tags", [])
                if self.mode == "diff":
                    self.log(f"notification '{name}': would create")
                else:
                    self.api_post("notification", new_entry)
                    self.log(f"notification '{name}': created")

    def _sync_download_clients(self):
        if not self.import_category_field:
            return

        clients = self.api_get("downloadclient")
        for client in clients:
            if client.get("implementation") != "QBittorrent":
                continue
            for field in client.get("fields", []):
                if field["name"] == self.import_category_field:
                    if field["value"] != self.import_category_value:
                        if self.mode == "diff":
                            self.log(
                                f"download client: would set {self.import_category_field} '{field['value']}' -> '{self.import_category_value}'"
                            )
                        else:
                            field["value"] = self.import_category_value
                            self.api_put(f"downloadclient/{client['id']}", client)
                            self.log(
                                f"download client: set {self.import_category_field} -> '{self.import_category_value}'"
                            )
                    else:
                        self.log("download client: post-import category in sync")
                    break
