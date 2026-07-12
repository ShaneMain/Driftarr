"""Tests for RadarrModule (configs/sync/modules/radarr.py)."""

from unittest.mock import patch


class TestRadarrInit:
    def test_attributes(self, radarr):
        assert radarr.name == "radarr"
        assert radarr.url_env == "RADARR_URL"
        assert radarr.key_env == "RADARR_API_KEY"
        assert radarr.import_category_field == "movieImportedCategory"
        assert radarr.import_category_value == "movies-imported"

    def test_expected_files(self, radarr):
        expected = [
            "custom-formats.json", "profile-scores.json",
            "quality-definitions.json", "naming.json",
            "media-management.json", "root-folders.json",
        ]
        assert radarr.expected_files == expected


class TestRadarrExport:
    def test_export_custom_formats(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[
            {"id": 1, "name": "BR-DISK", "includeCustomFormatWhenRenaming": False, "specifications": [
                {"name": "spec1", "implementation": "impl", "negate": False, "required": True,
                 "fields": [{"name": "value", "value": "test"}]}
            ]},
        ]):
            radarr._export_custom_formats()
            data = radarr.load_json("custom-formats.json")
            assert len(data) == 1
            assert data[0]["name"] == "BR-DISK"
            assert "id" not in data[0]  # IDs stripped on export

    def test_export_profile_scores(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[
            {"id": 1, "name": "HD", "minFormatScore": 0, "cutoffFormatScore": 0,
             "formatItems": [{"name": "BR-DISK", "score": 100}, {"name": "HC", "score": 0}]},
        ]):
            radarr._export_profile_scores()
            data = radarr.load_json("profile-scores.json")
            assert "HD" in data
            assert data["HD"]["formatScores"] == {"BR-DISK": 100}  # score=0 excluded

    def test_export_naming_strips_id(self, radarr):
        with patch.object(radarr, 'api_get', return_value={"id": 1, "renameMovies": True}):
            radarr._export_naming()
            data = radarr.load_json("naming.json")
            assert "id" not in data
            assert data["renameMovies"] is True

    def test_export_media_management_strips_id(self, radarr):
        with patch.object(radarr, 'api_get', return_value={"id": 1, "autoUnmonitor": True}):
            radarr._export_media_management()
            data = radarr.load_json("media-management.json")
            assert "id" not in data

    def test_export_root_folders(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[
            {"id": 1, "path": "/movies", "accessible": True, "freeSpace": 123456},
        ]):
            radarr._export_root_folders()
            data = radarr.load_json("root-folders.json")
            assert data == [{"path": "/movies"}]  # Only path kept

    def test_export_quality_definitions(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[
            {"id": 1, "title": "HDTV-720p", "minSize": 0, "maxSize": 100, "preferredSize": 50},
        ]):
            radarr._export_quality_definitions()
            data = radarr.load_json("quality-definitions.json")
            assert len(data) == 1
            assert data[0]["title"] == "HDTV-720p"
            assert "id" not in data[0]


class TestRadarrSyncCustomFormats:
    def test_creates_missing_format(self, radarr):
        radarr.write_json("custom-formats.json", [
            {"name": "NewCF", "includeCustomFormatWhenRenaming": False, "specifications": []},
        ])
        with patch.object(radarr, 'api_get', return_value=[]):
            with patch.object(radarr, 'api_post') as mock_post:
                radarr._sync_custom_formats()
                mock_post.assert_called_once()
                assert mock_post.call_args[0][1]["name"] == "NewCF"

    def test_updates_changed_format(self, radarr):
        radarr.write_json("custom-formats.json", [
            {"name": "CF1", "includeCustomFormatWhenRenaming": True, "specifications": []},
        ])
        with patch.object(radarr, 'api_get', return_value=[
            {"id": 5, "name": "CF1", "includeCustomFormatWhenRenaming": False, "specifications": []},
        ]):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_custom_formats()
                mock_put.assert_called_once()
                assert mock_put.call_args[0][0] == "customformat/5"

    def test_deletes_extra_format(self, radarr):
        radarr.write_json("custom-formats.json", [])  # Empty = delete all
        with patch.object(radarr, 'api_get', return_value=[
            {"id": 5, "name": "OldCF", "specifications": []},
        ]):
            with patch.object(radarr, 'api_delete') as mock_del:
                radarr._sync_custom_formats()
                mock_del.assert_called_once_with("customformat/5")

    def test_missing_file_non_bootstrap_deletes_all(self, radarr):
        # No file written, but not in bootstrap mode
        with patch.object(radarr, 'is_bootstrap_mode', return_value=False):
            with patch.object(radarr, 'api_get', return_value=[
                {"id": 1, "name": "X", "specifications": []},
            ]):
                with patch.object(radarr, 'api_delete') as mock_del:
                    radarr._sync_custom_formats()
                    mock_del.assert_called_once()

    def test_missing_file_bootstrap_skips(self, radarr):
        # No file, bootstrap mode — should not delete
        with patch.object(radarr, 'api_get') as mock_get:
            radarr._sync_custom_formats()
            mock_get.assert_not_called()


class TestRadarrSyncSingletons:
    def test_naming_updates_when_different(self, radarr):
        radarr.write_json("naming.json", {"renameMovies": True})
        with patch.object(radarr, 'api_get', return_value={"id": 1, "renameMovies": False}):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_naming()
                mock_put.assert_called_once()
                sent = mock_put.call_args[0][1]
                assert sent["renameMovies"] is True
                assert sent["id"] == 1  # ID injected for PUT

    def test_naming_skips_when_in_sync(self, radarr):
        radarr.write_json("naming.json", {"renameMovies": True})
        with patch.object(radarr, 'api_get', return_value={"id": 1, "renameMovies": True}):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_naming()
                mock_put.assert_not_called()

    def test_naming_skips_when_no_file(self, radarr):
        with patch.object(radarr, 'api_get') as mock_get:
            radarr._sync_naming()
            mock_get.assert_not_called()

    def test_media_management_updates(self, radarr):
        radarr.write_json("media-management.json", {"autoUnmonitor": True})
        with patch.object(radarr, 'api_get', return_value={"id": 1, "autoUnmonitor": False}):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_media_management()
                mock_put.assert_called_once()


class TestRadarrSyncRootFolders:
    def test_adds_missing_folder(self, radarr):
        radarr.write_json("root-folders.json", [{"path": "/new"}])
        with patch.object(radarr, 'api_get', return_value=[]):
            with patch.object(radarr, 'api_post') as mock_post:
                radarr._sync_root_folders()
                mock_post.assert_called_once()
                assert mock_post.call_args[0][1]["path"] == "/new"

    def test_deletes_extra_folder(self, radarr):
        radarr.write_json("root-folders.json", [])
        with patch.object(radarr, 'is_bootstrap_mode', return_value=False):
            with patch.object(radarr, 'api_get', return_value=[{"id": 1, "path": "/old"}]):
                with patch.object(radarr, 'api_delete') as mock_del:
                    radarr._sync_root_folders()
                    mock_del.assert_called_once_with("rootfolder/1")


class TestRadarrSyncDownloadClients:
    def test_updates_import_category(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[{
            "id": 1, "implementation": "QBittorrent",
            "fields": [{"name": "movieImportedCategory", "value": "wrong"}],
        }]):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_download_clients()
                mock_put.assert_called_once()
                client = mock_put.call_args[0][1]
                field = next(f for f in client["fields"] if f["name"] == "movieImportedCategory")
                assert field["value"] == "movies-imported"

    def test_skips_when_in_sync(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[{
            "id": 1, "implementation": "QBittorrent",
            "fields": [{"name": "movieImportedCategory", "value": "movies-imported"}],
        }]):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_download_clients()
                mock_put.assert_not_called()

    def test_ignores_non_qbittorrent(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[{
            "id": 1, "implementation": "SABnzbd", "fields": [],
        }]):
            with patch.object(radarr, 'api_put') as mock_put:
                radarr._sync_download_clients()
                mock_put.assert_not_called()


class TestRadarrDiffMode:
    def test_diff_mode_does_not_write(self, radarr_diff):
        radarr_diff.write_json("naming.json", {"renameMovies": True})
        with patch.object(radarr_diff, 'api_get', return_value={"id": 1, "renameMovies": False}):
            with patch.object(radarr_diff, 'api_put') as mock_put:
                radarr_diff._sync_naming()
                mock_put.assert_not_called()


def _gate_desired():
    return [{
        "name": "freeleech-gate",
        "implementation": "CustomScript",
        "onGrab": True,
        "fields": [{"name": "path", "value": "/usr/local/bin/freeleech-gate.sh"}],
    }]


def _schema_customscript():
    return [{
        "implementation": "CustomScript",
        "configContract": "CustomScriptSettings",
        "onGrab": False,
        "onDownload": False,
        "onUpgrade": False,
        "onRename": False,
        "onHealthIssue": False,
        "tags": [],
        "fields": [
            {"name": "path", "value": ""},
            {"name": "arguments", "value": ""},
        ],
    }]


class TestRadarrSyncNotifications:
    """Additive semantics: declared entries are reconciled; undeclared ones stay."""

    def test_missing_file_is_noop(self, radarr):
        """No notifications.json = nothing declared. Must not touch the API."""
        with patch.object(radarr, 'api_get') as mock_get:
            radarr._sync_notifications()
            mock_get.assert_not_called()

    def test_creates_missing_entry_using_schema_template(self, radarr):
        radarr.write_json("notifications.json", _gate_desired())

        def api_get(endpoint):
            if endpoint == "notification":
                return []
            if endpoint == "notification/schema":
                return _schema_customscript()
            raise AssertionError(f"unexpected api_get({endpoint})")

        with patch.object(radarr, 'api_get', side_effect=api_get), \
             patch.object(radarr, 'api_post') as mock_post, \
             patch.object(radarr, 'api_put') as mock_put, \
             patch.object(radarr, 'api_delete') as mock_delete:
            radarr._sync_notifications()

        mock_post.assert_called_once()
        mock_put.assert_not_called()
        mock_delete.assert_not_called()
        posted = mock_post.call_args[0][1]
        assert posted["name"] == "freeleech-gate"
        assert posted["implementation"] == "CustomScript"
        assert posted["onGrab"] is True
        # Path field populated from desired, other schema fields preserved
        fields = {f["name"]: f["value"] for f in posted["fields"]}
        assert fields["path"] == "/usr/local/bin/freeleech-gate.sh"
        assert "arguments" in fields

    def test_noop_when_existing_matches(self, radarr):
        radarr.write_json("notifications.json", _gate_desired())
        existing = [{
            "id": 9,
            "name": "freeleech-gate",
            "implementation": "CustomScript",
            "onGrab": True,
            "onDownload": False,
            "onUpgrade": False,
            "tags": [],
            "fields": [
                {"name": "path", "value": "/usr/local/bin/freeleech-gate.sh"},
                {"name": "arguments", "value": ""},
            ],
        }]
        with patch.object(radarr, 'api_get', return_value=existing), \
             patch.object(radarr, 'api_post') as mock_post, \
             patch.object(radarr, 'api_put') as mock_put:
            radarr._sync_notifications()

        mock_post.assert_not_called()
        mock_put.assert_not_called()

    def test_updates_when_path_diverges(self, radarr):
        radarr.write_json("notifications.json", _gate_desired())
        existing = [{
            "id": 9,
            "name": "freeleech-gate",
            "implementation": "CustomScript",
            "onGrab": True,
            "tags": [],
            "fields": [
                {"name": "path", "value": "/wrong/path.sh"},
                {"name": "arguments", "value": ""},
            ],
        }]
        with patch.object(radarr, 'api_get', return_value=existing), \
             patch.object(radarr, 'api_put') as mock_put:
            radarr._sync_notifications()

        mock_put.assert_called_once()
        body = mock_put.call_args[0][1]
        path = next(f["value"] for f in body["fields"] if f["name"] == "path")
        assert path == "/usr/local/bin/freeleech-gate.sh"

    def test_updates_when_toggle_diverges(self, radarr):
        radarr.write_json("notifications.json", _gate_desired())
        existing = [{
            "id": 9,
            "name": "freeleech-gate",
            "implementation": "CustomScript",
            "onGrab": False,  # desired=True
            "onDownload": True,  # undeclared; must be reset to False
            "tags": [],
            "fields": [
                {"name": "path", "value": "/usr/local/bin/freeleech-gate.sh"},
                {"name": "arguments", "value": ""},
            ],
        }]
        with patch.object(radarr, 'api_get', return_value=existing), \
             patch.object(radarr, 'api_put') as mock_put:
            radarr._sync_notifications()

        mock_put.assert_called_once()
        body = mock_put.call_args[0][1]
        assert body["onGrab"] is True
        assert body["onDownload"] is False

    def test_does_not_delete_undeclared_entries(self, radarr):
        """User-added Discord/webhook entries must survive — additive-only."""
        radarr.write_json("notifications.json", _gate_desired())
        existing = [
            {
                "id": 9,
                "name": "freeleech-gate",
                "implementation": "CustomScript",
                "onGrab": True,
                "tags": [],
                "fields": [
                    {"name": "path", "value": "/usr/local/bin/freeleech-gate.sh"},
                    {"name": "arguments", "value": ""},
                ],
            },
            {
                "id": 10,
                "name": "user-discord",
                "implementation": "Discord",
                "onGrab": True,
                "tags": [],
                "fields": [{"name": "webHookUrl", "value": "https://..."}],
            },
        ]
        with patch.object(radarr, 'api_get', return_value=existing), \
             patch.object(radarr, 'api_delete') as mock_delete:
            radarr._sync_notifications()

        mock_delete.assert_not_called()

    def test_diff_mode_does_not_call_write_apis(self, radarr_diff):
        radarr_diff.write_json("notifications.json", _gate_desired())

        def api_get(endpoint):
            if endpoint == "notification":
                return []
            if endpoint == "notification/schema":
                return _schema_customscript()
            raise AssertionError(f"unexpected api_get({endpoint})")

        with patch.object(radarr_diff, 'api_get', side_effect=api_get), \
             patch.object(radarr_diff, 'api_post') as mock_post, \
             patch.object(radarr_diff, 'api_put') as mock_put:
            radarr_diff._sync_notifications()

        mock_post.assert_not_called()
        mock_put.assert_not_called()

    def test_warns_on_unknown_implementation(self, radarr):
        radarr.write_json("notifications.json", [{
            "name": "bogus",
            "implementation": "NotAThing",
            "onGrab": True,
            "fields": [],
        }])

        def api_get(endpoint):
            if endpoint == "notification":
                return []
            if endpoint == "notification/schema":
                return _schema_customscript()
            raise AssertionError(endpoint)

        with patch.object(radarr, 'api_get', side_effect=api_get), \
             patch.object(radarr, 'api_post') as mock_post:
            radarr._sync_notifications()
        mock_post.assert_not_called()


class TestRadarrExportNotifications:
    def test_exports_only_truthy_toggles(self, radarr):
        with patch.object(radarr, 'api_get', return_value=[{
            "id": 1,
            "name": "freeleech-gate",
            "implementation": "CustomScript",
            "onGrab": True,
            "onDownload": False,
            "onUpgrade": False,
            "tags": [],
            "fields": [
                {"name": "path", "value": "/usr/local/bin/freeleech-gate.sh"},
                {"name": "arguments", "value": ""},
            ],
        }]):
            radarr._export_notifications()

        data = radarr.load_json("notifications.json")
        assert data[0]["name"] == "freeleech-gate"
        assert data[0]["onGrab"] is True
        assert "onDownload" not in data[0]
        # Empty-string fields should be dropped on export
        field_names = {f["name"] for f in data[0]["fields"]}
        assert "path" in field_names
        assert "arguments" not in field_names
