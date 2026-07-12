"""Tests for SonarrModule (configs/sync/modules/sonarr.py)."""

from unittest.mock import patch

from configs.sync.modules.radarr import RadarrModule
from configs.sync.modules.sonarr import SonarrModule


class TestSonarrInit:
    def test_inherits_radarr(self):
        assert issubclass(SonarrModule, RadarrModule)

    def test_overrides(self, sonarr):
        assert sonarr.name == "sonarr"
        assert sonarr.url_env == "SONARR_URL"
        assert sonarr.key_env == "SONARR_API_KEY"
        assert sonarr.default_url == "http://sonarr:8989"

    def test_import_category(self, sonarr):
        assert sonarr.import_category_field == "tvImportedCategory"
        assert sonarr.import_category_value == "tv-imported"

    def test_expected_files_same_as_radarr(self, radarr, sonarr):
        assert sonarr.expected_files == radarr.expected_files


class TestSonarrInheritedBehavior:
    """Sonarr should behave identically to Radarr for shared logic."""

    def test_export_custom_formats(self, sonarr):
        with patch.object(sonarr, 'api_get', return_value=[
            {"id": 1, "name": "WEBDL", "includeCustomFormatWhenRenaming": False, "specifications": []},
        ]):
            sonarr._export_custom_formats()
            data = sonarr.load_json("custom-formats.json")
            assert len(data) == 1
            assert data[0]["name"] == "WEBDL"

    def test_sync_naming(self, sonarr):
        sonarr.write_json("naming.json", {"renameEpisodes": True})
        with patch.object(sonarr, 'api_get', return_value={"id": 1, "renameEpisodes": False}):
            with patch.object(sonarr, 'api_put') as mock_put:
                sonarr._sync_naming()
                mock_put.assert_called_once()

    def test_download_client_uses_tv_category(self, sonarr):
        with patch.object(sonarr, 'api_get', return_value=[{
            "id": 1, "implementation": "QBittorrent",
            "fields": [{"name": "tvImportedCategory", "value": "wrong"}],
        }]):
            with patch.object(sonarr, 'api_put') as mock_put:
                sonarr._sync_download_clients()
                mock_put.assert_called_once()
                client = mock_put.call_args[0][1]
                field = next(f for f in client["fields"] if f["name"] == "tvImportedCategory")
                assert field["value"] == "tv-imported"
