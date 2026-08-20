"""Tests for QbittorrentModule (configs/sync/modules/qbittorrent.py)."""

import json
from unittest.mock import patch

from configs.sync.modules.qbittorrent import EXCLUDED_KEYS, QbittorrentModule


class TestQbittorrentInit:
    def test_attributes(self, qbittorrent):
        assert qbittorrent.name == "qbittorrent"
        assert qbittorrent.url_env == "QBITTORRENT_URL"
        assert qbittorrent.key_env == ""
        assert qbittorrent.expected_files == ["preferences.json"]

    def test_no_api_key(self, qbittorrent):
        assert not qbittorrent.api_key


class TestExcludedKeys:
    def test_credentials_excluded(self):
        for key in ("web_ui_username", "web_ui_password", "proxy_password", "proxy_username"):
            assert key in EXCLUDED_KEYS

    def test_ssl_paths_excluded(self):
        for key in ("web_ui_https_cert_path", "web_ui_https_key_path"):
            assert key in EXCLUDED_KEYS

    def test_instance_paths_excluded(self):
        for key in ("save_path", "temp_path", "scan_dirs"):
            assert key in EXCLUDED_KEYS

    def test_listen_port_excluded(self):
        assert "listen_port" in EXCLUDED_KEYS


class TestQbittorrentExport:
    def test_export_filters_excluded_keys(self, qbittorrent):
        raw_prefs = {
            "max_active_downloads": 3,
            "max_active_uploads": 3,
            "web_ui_username": "admin",
            "web_ui_password": "secret",
            "listen_port": 6881,
            "save_path": "/downloads",
        }
        with patch.object(qbittorrent, '_qbit_get', return_value=raw_prefs):
            qbittorrent.export()
            data = qbittorrent.load_json("preferences.json")
            assert "max_active_downloads" in data
            assert "max_active_uploads" in data
            assert "web_ui_username" not in data
            assert "web_ui_password" not in data
            assert "listen_port" not in data
            assert "save_path" not in data

    def test_export_sorts_keys(self, qbittorrent):
        with patch.object(qbittorrent, '_qbit_get', return_value={"z_key": 1, "a_key": 2}):
            qbittorrent.export()
            data = qbittorrent.load_json("preferences.json")
            keys = list(data.keys())
            assert keys == sorted(keys)


class TestQbittorrentSync:
    def test_applies_changed_prefs(self, qbittorrent):
        qbittorrent.write_json("preferences.json", {
            "max_active_downloads": 5,
            "max_active_uploads": 3,
        })
        with patch.object(qbittorrent, '_qbit_get', return_value={
            "max_active_downloads": 3,
            "max_active_uploads": 3,
        }):
            with patch.object(qbittorrent, '_qbit_post_prefs') as mock_post:
                qbittorrent.sync()
                mock_post.assert_called_once()
                diff = mock_post.call_args[0][0]
                assert diff == {"max_active_downloads": 5}

    def test_skips_when_in_sync(self, qbittorrent):
        qbittorrent.write_json("preferences.json", {"max_active_downloads": 3})
        with patch.object(qbittorrent, '_qbit_get', return_value={"max_active_downloads": 3}):
            with patch.object(qbittorrent, '_qbit_post_prefs') as mock_post:
                qbittorrent.sync()
                mock_post.assert_not_called()

    def test_skips_excluded_keys_in_desired(self, qbittorrent):
        qbittorrent.write_json("preferences.json", {
            "max_active_downloads": 5,
            "web_ui_username": "hacker",  # Should be ignored
        })
        with patch.object(qbittorrent, '_qbit_get', return_value={
            "max_active_downloads": 3,
            "web_ui_username": "admin",
        }):
            with patch.object(qbittorrent, '_qbit_post_prefs') as mock_post:
                qbittorrent.sync()
                diff = mock_post.call_args[0][0]
                assert "web_ui_username" not in diff
                assert "max_active_downloads" in diff

    def test_no_file_skips(self, qbittorrent):
        with patch.object(qbittorrent, '_qbit_get') as mock_get:
            qbittorrent.sync()
            mock_get.assert_not_called()

    def test_diff_mode_does_not_post(self, data_dir):
        import os
        with patch.dict(os.environ, {"QBITTORRENT_URL": "http://localhost:8080"}):
            mod = QbittorrentModule(data_dir=data_dir, mode="diff")
        mod.write_json("preferences.json", {"max_active_downloads": 5})
        with patch.object(mod, '_qbit_get', return_value={"max_active_downloads": 3}):
            with patch.object(mod, '_qbit_post_prefs') as mock_post:
                mod.sync()
                mock_post.assert_not_called()


class TestQbittorrentPostEncoding:
    def test_set_preferences_body_is_form_encoded(self, qbittorrent):
        """H5: values with &, +, % must survive the form decoder."""
        import urllib.parse

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
            captured["ctype"] = req.get_header("Content-type")
            return _Resp()

        prefs = {"autorun_program": "/bin/x %F", "announce_ip": "a&b+c"}
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            qbittorrent._qbit_post_prefs(prefs)
        assert captured["ctype"] == "application/x-www-form-urlencoded"
        assert "&b" not in captured["body"] and "%F " not in captured["body"]
        decoded = urllib.parse.parse_qs(captured["body"])
        assert json.loads(decoded["json"][0]) == prefs
