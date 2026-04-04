"""Tests for AppModule base class (configs/sync/base.py)."""

import json
import os
import pytest
from unittest.mock import patch, MagicMock

from configs.sync.base import AppModule


class TestAppModuleInit:
    """Test module initialization and config loading."""

    def test_url_from_env(self, data_dir):
        with patch.dict(os.environ, {"RADARR_URL": "http://custom:9999", "RADARR_API_KEY": "k"}):
            from configs.sync.modules.radarr import RadarrModule
            mod = RadarrModule(data_dir, "sync")
            assert mod.url == "http://custom:9999"

    def test_url_falls_back_to_default(self, data_dir):
        with patch.dict(os.environ, {}, clear=True):
            from configs.sync.modules.radarr import RadarrModule
            mod = RadarrModule(data_dir, "sync")
            assert mod.url == RadarrModule.default_url

    def test_api_key_from_env(self, data_dir):
        with patch.dict(os.environ, {"RADARR_URL": "http://x", "RADARR_API_KEY": "secret123"}):
            from configs.sync.modules.radarr import RadarrModule
            mod = RadarrModule(data_dir, "sync")
            assert mod.api_key == "secret123"

    def test_data_dir_set(self, radarr):
        assert radarr.data_dir.name == "radarr"


class TestJsonIO:
    """Test load_json and write_json."""

    def test_write_then_load(self, radarr):
        data = {"key": "value", "nested": {"a": 1}}
        radarr.write_json("test.json", data)
        loaded = radarr.load_json("test.json")
        assert loaded == data

    def test_load_missing_returns_none(self, radarr):
        result = radarr.load_json("nonexistent.json")
        assert result is None

    def test_write_creates_directory(self, data_dir):
        with patch.dict(os.environ, {"RADARR_URL": "http://x", "RADARR_API_KEY": "k"}):
            from configs.sync.modules.radarr import RadarrModule
            mod = RadarrModule(data_dir, "sync")
            # data_dir/radarr/ doesn't exist yet
            mod.write_json("test.json", {"a": 1})
            assert (data_dir / "radarr" / "test.json").exists()


class TestBootstrapMode:
    """Test is_bootstrap_mode detection."""

    def test_bootstrap_when_no_dir(self, radarr):
        # data_dir/radarr/ doesn't exist yet
        assert radarr.is_bootstrap_mode() is True

    def test_bootstrap_when_empty_dir(self, radarr):
        radarr.data_dir.mkdir(parents=True, exist_ok=True)
        assert radarr.is_bootstrap_mode() is True

    def test_not_bootstrap_when_files_exist(self, radarr):
        for f in radarr.expected_files:
            radarr.write_json(f, {})
        assert radarr.is_bootstrap_mode() is False

    def test_bootstrap_when_expected_file_missing(self, radarr):
        # Write all but one
        for f in radarr.expected_files[:-1]:
            radarr.write_json(f, {})
        assert radarr.is_bootstrap_mode() is True


class TestApiHelpers:
    """Test _request, api_get, api_put, api_post, api_delete."""

    def test_api_get_calls_request(self, radarr):
        with patch.object(radarr, '_request', return_value=[{"id": 1}]) as mock:
            result = radarr.api_get("customformat")
            mock.assert_called_once()
            assert "customformat" in mock.call_args[0][0]
            assert result == [{"id": 1}]

    def test_api_put_sends_data(self, radarr):
        with patch.object(radarr, '_request', return_value=None) as mock:
            radarr.api_put("customformat/1", {"id": 1, "name": "test"})
            mock.assert_called_once()
            assert mock.call_args[0][1] == "PUT"
            assert mock.call_args[0][2] == {"id": 1, "name": "test"}

    def test_api_post_sends_data(self, radarr):
        with patch.object(radarr, '_request', return_value={"id": 99}) as mock:
            result = radarr.api_post("customformat", {"name": "new"})
            mock.assert_called_once()
            assert mock.call_args[0][1] == "POST"
            assert result == {"id": 99}

    def test_api_delete(self, radarr):
        with patch.object(radarr, '_request', return_value=None) as mock:
            radarr.api_delete("customformat/1")
            mock.assert_called_once()
            assert mock.call_args[0][1] == "DELETE"

    def test_request_wraps_http_error(self, radarr):
        import urllib.error
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_urlopen.side_effect = urllib.error.HTTPError(
                "http://x", 500, "fail", {}, None
            )
            with pytest.raises(RuntimeError, match="500"):
                radarr._request("http://x/test", "GET")
