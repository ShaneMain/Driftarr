"""Tests for AppModule base class (configs/sync/base.py)."""

import io
import os
import urllib.error
from unittest.mock import patch

import pytest

from configs.sync.base import REDACTED, AppModule, AuthError, is_secret_sentinel


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

    def test_write_json_sorts_keys(self, radarr):
        """write_json must produce sorted-key output for deterministic diffs."""
        radarr.write_json("sorted.json", {"z": 1, "a": 2, "m": {"y": 0, "b": 1}})
        raw = (radarr.data_dir / "sorted.json").read_text()
        # Keys should appear in alphabetical order in the file
        assert raw.index('"a"') < raw.index('"m"') < raw.index('"z"')
        assert raw.index('"b"') < raw.index('"y"')

    def test_write_json_deterministic_across_insertion_order(self, radarr):
        """Same data with different dict insertion order must produce identical bytes."""
        d1 = {"zebra": 1, "alpha": 2, "mid": {"y": 0, "a": 1}}
        d2 = {"alpha": 2, "mid": {"a": 1, "y": 0}, "zebra": 1}
        radarr.write_json("d1.json", d1)
        radarr.write_json("d2.json", d2)
        f1 = (radarr.data_dir / "d1.json").read_text()
        f2 = (radarr.data_dir / "d2.json").read_text()
        assert f1 == f2


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
        with patch.object(radarr, "_request", return_value=[{"id": 1}]) as mock:
            result = radarr.api_get("customformat")
            mock.assert_called_once()
            assert "customformat" in mock.call_args[0][0]
            assert result == [{"id": 1}]

    def test_api_put_sends_data(self, radarr):
        with patch.object(radarr, "_request", return_value=None) as mock:
            radarr.api_put("customformat/1", {"id": 1, "name": "test"})
            mock.assert_called_once()
            assert mock.call_args[0][1] == "PUT"
            assert mock.call_args[0][2] == {"id": 1, "name": "test"}

    def test_api_post_sends_data(self, radarr):
        with patch.object(radarr, "_request", return_value={"id": 99}) as mock:
            result = radarr.api_post("customformat", {"name": "new"})
            mock.assert_called_once()
            assert mock.call_args[0][1] == "POST"
            assert result == {"id": 99}

    def test_api_delete(self, radarr):
        with patch.object(radarr, "_request", return_value=None) as mock:
            radarr.api_delete("customformat/1")
            mock.assert_called_once()
            assert mock.call_args[0][1] == "DELETE"

    def test_request_wraps_http_error(self, radarr):
        import urllib.error

        with patch("urllib.request.urlopen") as mock_urlopen:
            mock_urlopen.side_effect = urllib.error.HTTPError("http://x", 500, "fail", {}, None)
            with pytest.raises(RuntimeError, match="500"):
                radarr._request("http://x/test", "GET")


class TestExpandEnv:
    """Env-var interpolation for secret placeholders."""

    def test_substitutes_single_placeholder(self):
        with patch.dict(os.environ, {"SECRET": "hunter2"}):
            assert AppModule.expand_env("${SECRET}") == "hunter2"

    def test_substitutes_in_dict_values(self):
        with patch.dict(os.environ, {"USER": "alice", "PASS": "pw"}):
            result = AppModule.expand_env(
                {"Server.Username": "${USER}", "Server.Password": "${PASS}"}
            )
            assert result == {"Server.Username": "alice", "Server.Password": "pw"}

    def test_missing_var_left_unexpanded(self):
        """C1: an unset var must not silently become "" (wiped live secrets)."""
        with patch.dict(os.environ, {}, clear=True):
            assert AppModule.expand_env("${NOT_SET}") == "${NOT_SET}"

    def test_empty_var_left_unexpanded(self):
        """compose passes ${VAR:-} — empty is as good as unset."""
        with patch.dict(os.environ, {"EMPTY": ""}):
            assert AppModule.expand_env("key=${EMPTY}") == "key=${EMPTY}"

    def test_has_placeholder_and_unresolved_vars(self):
        with patch.dict(os.environ, {"A": "1"}, clear=True):
            out = AppModule.expand_env({"a": "${A}", "b": ["${B}"], "c": {"d": "${C}-${B}"}})
        assert AppModule.has_placeholder(out["a"]) is False
        assert AppModule.has_placeholder(out["b"][0]) is True
        assert AppModule.has_placeholder(42) is False
        assert AppModule.unresolved_vars(out) == {"B", "C"}

    def test_expand_env_or_redact_warns_once_and_redacts(self, radarr, capsys):
        with patch.dict(os.environ, {"A": "1"}, clear=True):
            out = radarr.expand_env_or_redact({"a": "${A}", "b": "${B}", "n": 3, "l": ["${C}"]})
        assert out == {"a": "1", "b": REDACTED, "n": 3, "l": [REDACTED]}
        lines = [ln for ln in capsys.readouterr().out.splitlines() if "WARNING" in ln]
        assert len(lines) == 1
        assert "B, C" in lines[0]

    def test_expand_env_or_redact_silent_when_resolved(self, radarr, capsys):
        with patch.dict(os.environ, {"A": "1"}):
            assert radarr.expand_env_or_redact({"a": "${A}"}) == {"a": "1"}
        assert "WARNING" not in capsys.readouterr().out

    def test_is_secret_sentinel(self):
        assert is_secret_sentinel("<REDACTED>")
        assert is_secret_sentinel("********")
        assert not is_secret_sentinel("real")
        assert not is_secret_sentinel(None)

    def test_non_strings_pass_through(self):
        with patch.dict(os.environ, {"X": "1"}):
            assert AppModule.expand_env({"n": 42, "b": True, "s": "${X}"}) == {
                "n": 42,
                "b": True,
                "s": "1",
            }

    def test_recursive_into_lists(self):
        with patch.dict(os.environ, {"A": "x", "B": "y"}):
            assert AppModule.expand_env(["${A}", "${B}", "plain"]) == ["x", "y", "plain"]


class TestReconcileDestructive:
    """Merge-before-write primitive for destructive APIs (e.g. NZBget saveconfig)."""

    class _FakeModule(AppModule):
        name = "fake"
        url_env = "FAKE_URL"
        default_url = "http://fake"

        def __init__(self, data_dir, mode, current):
            super().__init__(data_dir, mode)
            self._current = dict(current)
            self.written = None

        def fetch_config(self):
            return dict(self._current)

        def write_config(self, full):
            self.written = dict(full)

    def _make(self, data_dir, mode, current):
        with patch.dict(os.environ, {"FAKE_URL": "http://x"}):
            return self._FakeModule(data_dir, mode, current)

    def test_writes_full_merged_set_on_change(self, data_dir):
        mod = self._make(data_dir, "sync", {"A": "1", "B": "2", "C": "3"})
        changed = mod.reconcile_destructive({"B": "99"})
        assert changed == {"B"}
        assert mod.written == {"A": "1", "B": "99", "C": "3"}  # full set preserved

    def test_noop_when_desired_matches_current(self, data_dir):
        mod = self._make(data_dir, "sync", {"A": "1", "B": "2"})
        changed = mod.reconcile_destructive({"A": "1"})
        assert changed == set()
        assert mod.written is None

    def test_adds_new_keys(self, data_dir):
        mod = self._make(data_dir, "sync", {"A": "1"})
        changed = mod.reconcile_destructive({"B": "2"})
        assert changed == {"B"}
        assert mod.written == {"A": "1", "B": "2"}

    def test_diff_mode_does_not_write(self, data_dir):
        mod = self._make(data_dir, "diff", {"A": "1"})
        changed = mod.reconcile_destructive({"A": "99"})
        assert changed == {"A"}
        assert mod.written is None  # dry run

    def test_string_coercion_for_comparison(self, data_dir):
        # Services like NZBget return stringified values; desired is also string.
        # An int-valued current should not register as change when desired=str.
        mod = self._make(data_dir, "sync", {"Port": 563})
        changed = mod.reconcile_destructive({"Port": "563"})
        assert changed == set()
        assert mod.written is None

    def test_sensitive_key_detection(self, data_dir):
        mod = self._make(data_dir, "sync", {"Server1.Password": "old"})
        # Just validating the classifier, not the log side-effect
        assert mod._is_sensitive("Server1.Password")
        assert mod._is_sensitive("API_TOKEN")
        assert not mod._is_sensitive("Server1.Host")


class TestApiKeyPublishing:
    """C1: a key resolved from config.xml must be visible to ${VAR} expansion."""

    def test_config_xml_key_published_to_env(self, data_dir, tmp_path):
        xml = tmp_path / "config.xml"
        xml.write_text("<Config><ApiKey>fromxml</ApiKey></Config>")

        class M(AppModule):
            name = "m"
            key_env = "PUBLISH_TEST_KEY"
            config_xml_path = str(xml)

        with patch.dict(os.environ, {}, clear=True):
            mod = M(data_dir)
            assert mod.api_key == "fromxml"
            assert os.environ["PUBLISH_TEST_KEY"] == "fromxml"
            assert AppModule.expand_env("${PUBLISH_TEST_KEY}") == "fromxml"

    def test_env_key_not_overwritten(self, data_dir):
        with patch.dict(os.environ, {"RADARR_API_KEY": "fromenv"}):
            from configs.sync.modules.radarr import RadarrModule

            RadarrModule(data_dir)
            assert os.environ["RADARR_API_KEY"] == "fromenv"


def _http_error(code):
    return urllib.error.HTTPError("http://x", code, "nope", {}, io.BytesIO(b"denied"))


class TestAuthFailure:
    """M8: a rejected key is reported as such, not as 'unreachable'."""

    def test_request_raises_auth_error(self, radarr):
        with patch("urllib.request.urlopen", side_effect=_http_error(401)):
            with pytest.raises(AuthError, match="401"):
                radarr.api_get("x")

    def test_wait_until_ready_stops_immediately_on_401(self, radarr, capsys):
        with patch("urllib.request.urlopen", side_effect=_http_error(401)), \
             patch("socket.getaddrinfo", return_value=[]), \
             patch("time.sleep") as sleep:
            assert radarr.wait_until_ready(timeout=60) is False
        sleep.assert_not_called()
        assert "rejected API key (HTTP 401)" in capsys.readouterr().out


class TestApiPrefix:
    def test_default_prefix_v3(self, radarr):
        with patch.object(radarr, "_request") as req:
            radarr.api_get("x")
        assert req.call_args[0][0] == "http://localhost:7878/api/v3/x"

    def test_subclass_prefix(self, data_dir):
        from configs.sync.modules.bazarr import BazarrModule
        from configs.sync.modules.prowlarr import ProwlarrModule

        with patch.dict(os.environ, {"BAZARR_API_KEY": "k", "PROWLARR_API_KEY": "k"}):
            b = BazarrModule(data_dir)
            pr = ProwlarrModule(data_dir)
        with patch.object(b, "_request") as req:
            b.api_get("system/settings")
        assert req.call_args[0][0] == "http://bazarr:6767/api/system/settings"
        with patch.object(pr, "_request") as req:
            pr.api_put("config/host", {})
        assert req.call_args[0][0] == "http://prowlarr:9696/api/v1/config/host"


class TestRunSteps:
    """H6: one failing step must not skip the rest, but must still fail the module."""

    def test_continues_after_failure_and_raises_summary(self, radarr, capsys):
        calls = []

        def ok():
            calls.append("ok")

        def boom():
            raise RuntimeError("kaboom")

        with pytest.raises(RuntimeError, match=r"1/3 step\(s\) failed.*first: kaboom"):
            radarr.run_steps([("first", boom), ("second", ok), ("third", ok)])
        assert calls == ["ok", "ok"]
        assert "ERROR in first: kaboom" in capsys.readouterr().out

    def test_no_raise_when_all_succeed(self, radarr):
        radarr.run_steps([("a", lambda: None)])
