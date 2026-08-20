"""Tests for ProwlarrModule (configs/sync/modules/prowlarr.py)."""

import os
from unittest.mock import patch

import pytest

from configs.sync.base import REDACTED
from configs.sync.modules.prowlarr import ProwlarrModule


@pytest.fixture
def prowlarr(data_dir):
    with patch.dict(os.environ, {"PROWLARR_API_KEY": "testkey"}):
        return ProwlarrModule(data_dir=data_dir, mode="sync")


def _remote_indexer(**overrides):
    idx = {
        "id": 3,
        "name": "TL",
        "implementation": "Cardigann",
        "enable": True,
        "priority": 25,
        "appProfileId": 1,
        "capabilities": {"big": True},
        "fields": [
            {"name": "definitionFile", "value": "torrentleech", "privacy": "normal"},
            {"name": "username", "value": "alice", "privacy": "normal"},
            {"name": "password", "value": "s3cret", "privacy": "normal"},
            {"name": "rss_key", "value": "rsskey123", "privacy": "password"},
            {"name": "baseUrl", "value": "https://tl", "privacy": "normal"},
        ],
    }
    idx.update(overrides)
    return idx


class TestProwlarrInit:
    def test_attributes(self, prowlarr):
        assert prowlarr.api_prefix == "api/v1"
        assert prowlarr.url == "http://prowlarr:9696"
        assert prowlarr.api_key == "testkey"


class TestProwlarrExportIndexers:
    def test_secret_fields_redacted_by_name_and_privacy(self, prowlarr):
        """C2: plaintext credentials must never reach git."""
        with patch.object(prowlarr, "api_get", return_value=[_remote_indexer()]):
            prowlarr._export_indexers()
        data = prowlarr.load_json("indexers.json")
        fields = {f["name"]: f["value"] for f in data[0]["fields"]}
        assert fields["password"] == REDACTED  # by name
        assert fields["username"] == REDACTED  # by name
        assert fields["rss_key"] == REDACTED  # by schema privacy attribute
        assert fields["definitionFile"] == "torrentleech"
        assert fields["baseUrl"] == "https://tl"
        assert "capabilities" not in data[0]
        assert "s3cret" not in (prowlarr.data_dir / "indexers.json").read_text()

    def test_empty_secret_stays_empty(self, prowlarr):
        idx = _remote_indexer(fields=[{"name": "password", "value": ""}])
        with patch.object(prowlarr, "api_get", return_value=[idx]):
            prowlarr._export_indexers()
        assert prowlarr.load_json("indexers.json")[0]["fields"] == [{"name": "password", "value": ""}]


class TestProwlarrSyncIndexers:
    def _desired(self, **field_overrides):
        fields = {
            "baseUrl": "https://tl",
            "definitionFile": "torrentleech",
            "password": REDACTED,
            "rss_key": "********",
            "username": REDACTED,
        }
        fields.update(field_overrides)
        return [{
            "name": "TL",
            "implementation": "Cardigann",
            "enable": True,
            "priority": 25,
            "appProfileId": 1,
            "fields": [{"name": k, "value": v} for k, v in sorted(fields.items())],
        }]

    def test_in_sync_when_only_secrets_differ(self, prowlarr):
        prowlarr.write_json("indexers.json", self._desired())
        with patch.object(prowlarr, "api_get", return_value=[_remote_indexer()]), \
             patch.object(prowlarr, "api_put") as put, \
             patch.object(prowlarr, "api_post") as post:
            prowlarr._sync_indexers()
        put.assert_not_called()
        post.assert_not_called()

    def test_update_merges_by_name_and_keeps_remote_secrets(self, prowlarr):
        prowlarr.write_json("indexers.json", self._desired(baseUrl="https://new"))
        with patch.object(prowlarr, "api_get", return_value=[_remote_indexer()]), \
             patch.object(prowlarr, "api_put") as put:
            prowlarr._sync_indexers()
        sent = put.call_args[0][1]
        assert put.call_args[0][0] == "indexer/3"
        fields = {f["name"]: f["value"] for f in sent["fields"]}
        assert fields["baseUrl"] == "https://new"
        assert fields["password"] == "s3cret"  # live value kept, sentinel never sent
        assert fields["rss_key"] == "rsskey123"
        assert fields["username"] == "alice"
        assert sent["capabilities"] == {"big": True}  # remote-only keys survive
        assert REDACTED not in str(sent) and "********" not in str(sent)

    def test_create_with_masked_secret_is_skipped_not_posted(self, prowlarr, capsys):
        prowlarr.write_json("indexers.json", self._desired())
        schema = [{"implementation": "Cardigann", "fields": [{"name": "password", "value": ""}]}]

        with patch.object(prowlarr, "api_get", side_effect=lambda e: [] if e == "indexer" else schema), \
             patch.object(prowlarr, "api_post") as post:
            prowlarr.sync()  # not a step error
        post.assert_not_called()
        assert "WARNING: cannot create indexer 'TL': secret field 'password' is masked" in capsys.readouterr().out

    def test_create_with_resolved_fields_posts(self, prowlarr):
        prowlarr.write_json("indexers.json", self._desired(password="pw", rss_key="rk", username="u"))
        schema = [{"implementation": "Cardigann",
                   "fields": [{"name": "password", "value": ""}, {"name": "extra", "value": "keep"}]}]
        with patch.object(prowlarr, "api_get", side_effect=lambda e: [] if e == "indexer" else schema), \
             patch.object(prowlarr, "api_post") as post:
            prowlarr._sync_indexers()
        fields = {f["name"]: f["value"] for f in post.call_args[0][1]["fields"]}
        assert fields["password"] == "pw" and fields["extra"] == "keep" and fields["rss_key"] == "rk"

    def test_schema_fetched_once_for_multiple_creates(self, prowlarr):
        base = self._desired(password="pw", rss_key="rk", username="u")
        desired = base + [{**base[0], "name": "TL2"}]
        prowlarr.write_json("indexers.json", desired)
        calls = []

        def api_get(endpoint):
            calls.append(endpoint)
            return [] if endpoint == "indexer" else [{"implementation": "Cardigann", "fields": []}]

        with patch.object(prowlarr, "api_get", side_effect=api_get), patch.object(prowlarr, "api_post"):
            prowlarr._sync_indexers()
        assert calls.count("indexer/schema") == 1

    def test_missing_file_skips(self, prowlarr):
        with patch.object(prowlarr, "api_get") as get, patch.object(prowlarr, "api_delete") as dele:
            prowlarr._sync_indexers()
        get.assert_not_called()
        dele.assert_not_called()


class TestProwlarrHostConfig:
    def test_export_uses_placeholder_for_api_key(self, prowlarr):
        with patch.object(prowlarr, "api_get", return_value={"id": 1, "apiKey": "k", "password": "p", "port": 9696}):
            prowlarr._export_host_config()
        data = prowlarr.load_json("host-config.json")
        assert data == {"apiKey": "${PROWLARR_API_KEY}", "password": REDACTED, "port": 9696}

    def test_unresolved_placeholder_keeps_live_value(self, prowlarr, capsys):
        """C1: unset PROWLARR_API_KEY must not PUT an empty apiKey."""
        prowlarr.write_json("host-config.json", {"apiKey": "${PROWLARR_API_KEY}", "port": 1})
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(prowlarr, "api_get", return_value={"id": 1, "apiKey": "live", "port": 2}), \
             patch.object(prowlarr, "api_put") as put:
            prowlarr._sync_host_config()
        sent = put.call_args[0][1]
        assert sent["apiKey"] == "live"
        assert sent["port"] == 1
        assert "WARNING: env var(s) not set: PROWLARR_API_KEY" in capsys.readouterr().out

    def test_resolved_placeholder_applied(self, prowlarr):
        prowlarr.write_json("host-config.json", {"apiKey": "${PROWLARR_API_KEY}"})
        with patch.dict(os.environ, {"PROWLARR_API_KEY": "rotated"}), \
             patch.object(prowlarr, "api_get", return_value={"id": 1, "apiKey": "old"}), \
             patch.object(prowlarr, "api_put") as put:
            prowlarr._sync_host_config()
        assert put.call_args[0][1]["apiKey"] == "rotated"


class TestProwlarrSyncSteps:
    def test_failing_indexers_step_does_not_skip_host_config(self, prowlarr):
        with patch.object(prowlarr, "_sync_indexers", side_effect=RuntimeError("boom")), \
             patch.object(prowlarr, "_sync_host_config") as host:
            with pytest.raises(RuntimeError, match="indexers: boom"):
                prowlarr.sync()
        host.assert_called_once()
