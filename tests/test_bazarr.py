"""Tests for BazarrModule (configs/sync/modules/bazarr.py)."""

import os
from unittest.mock import patch
from urllib.parse import parse_qs

import pytest

from configs.sync.base import REDACTED
from configs.sync.modules.bazarr import BazarrModule


@pytest.fixture
def bazarr(data_dir):
    with patch.dict(os.environ, {"BAZARR_API_KEY": "testkey"}):
        return BazarrModule(data_dir=data_dir, mode="sync")


class TestBazarrInit:
    def test_attributes(self, bazarr):
        assert bazarr.api_prefix == "api"
        assert bazarr.url == "http://bazarr:6767"


class TestBazarrExport:
    def test_secrets_redacted_and_mapped(self, bazarr):
        raw = {
            "auth": {"apikey": "k", "username": "u"},
            "radarr": {"apikey": "rk", "ip": "radarr"},
            "plex": {"token": "t"},
        }
        with patch.object(bazarr, "api_get", return_value=raw):
            bazarr._export_settings()
        data = bazarr.load_json("settings.json")
        assert data["auth"]["apikey"] == "${BAZARR_API_KEY}"
        assert data["radarr"]["apikey"] == "${RADARR_API_KEY}"
        assert data["plex"]["token"] == REDACTED
        assert data["radarr"]["ip"] == "radarr"


class TestBazarrSync:
    def _run(self, bazarr, desired, current, env):
        bazarr.write_json("settings.json", desired)
        with patch.dict(os.environ, env, clear=True), \
             patch.object(bazarr, "api_get", return_value=current), \
             patch.object(bazarr, "_post_settings_form") as post:
            bazarr._sync_settings()
        return post

    def test_unresolved_placeholder_keeps_live_secret(self, bazarr, capsys):
        """C1: missing RADARR_API_KEY must not blank Bazarr's Radarr key."""
        post = self._run(
            bazarr,
            {"radarr": {"apikey": "${RADARR_API_KEY}", "ip": "new-host"}},
            {"radarr": {"apikey": "live", "ip": "old-host"}},
            env={},
        )
        sent = post.call_args[0][0]
        assert sent == {"radarr": {"apikey": "live", "ip": "new-host"}}
        assert "WARNING: env var(s) not set: RADARR_API_KEY" in capsys.readouterr().out

    def test_resolved_placeholder_is_applied(self, bazarr):
        post = self._run(
            bazarr,
            {"radarr": {"apikey": "${RADARR_API_KEY}"}},
            {"radarr": {"apikey": "old"}},
            env={"RADARR_API_KEY": "rotated"},
        )
        assert post.call_args[0][0] == {"radarr": {"apikey": "rotated"}}

    def test_in_sync_with_redacted_secret(self, bazarr):
        post = self._run(
            bazarr,
            {"plex": {"token": REDACTED, "ip": "p"}},
            {"plex": {"token": "live", "ip": "p"}},
            env={},
        )
        post.assert_not_called()

    def test_missing_file_skips(self, bazarr):
        with patch.object(bazarr, "api_get") as get:
            bazarr._sync_settings()
        get.assert_not_called()

    def test_form_encoding(self, bazarr):
        captured = {}

        class _Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b""

        def fake_urlopen(req, timeout=0):
            captured["body"] = req.data.decode()
            return _Resp()

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            bazarr._post_settings_form({"general": {"a": True, "b": ["x", "y"], "c": None, "d": 1}})
        assert parse_qs(captured["body"], keep_blank_values=True) == {
            "settings-general-a": ["true"],
            "settings-general-b": ["x", "y"],
            "settings-general-c": [""],
            "settings-general-d": ["1"],
        }
