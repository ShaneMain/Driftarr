"""Tests for sync.py and export.py entry points."""

import os
import time
from unittest.mock import MagicMock, patch

import pytest

import configs.sync.export as export_mod
import configs.sync.sync as sync_mod


def _make_mod(name, data_dir, ready=True, has_data=False):
    """Build a mock module whose reachability and declared-data state are controlled."""
    mod = MagicMock()
    mod.name = name
    mod.url = f"http://{name}"
    mod.data_dir = data_dir / name
    mod.data_dir.mkdir(parents=True, exist_ok=True)
    if has_data:
        (mod.data_dir / "config.json").write_text("{}")
    mod.wait_until_ready.return_value = ready
    return mod


@pytest.fixture(autouse=True)
def _no_real_sleeps():
    """sync.py sleeps between retry attempts — make tests fast."""
    with patch.object(sync_mod.time, "sleep") as s:
        yield s


class TestSyncDiscovery:
    def test_discovers_shared_modules(self, data_dir):
        """Core sync modules shipped with the template."""
        modules = sync_mod.discover_modules(data_dir, "sync")
        names = {m.name for m in modules}
        assert "radarr" in names
        assert "sonarr" in names
        assert "qbittorrent" in names

    def test_no_duplicates(self, data_dir):
        modules = sync_mod.discover_modules(data_dir, "sync")
        names = [m.name for m in modules]
        assert len(names) == len(set(names))


class TestSyncMain:
    def test_calls_sync_on_ready_module(self, data_dir):
        mod = _make_mod("x", data_dir, ready=True, has_data=True)
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", MagicMock()):
            sync_mod.main()
        mod.sync.assert_called_once()

    def test_optional_unreachable_is_allowed(self, data_dir):
        """A module with NO declared data can be unreachable without failing the run."""
        mod = _make_mod("optional", data_dir, ready=False, has_data=False)
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", MagicMock()):
            sync_mod.main()  # no SystemExit
        mod.sync.assert_not_called()

    def test_required_unreachable_exits_nonzero(self, data_dir):
        """A module with declared data that never becomes reachable fails the run."""
        mod = _make_mod("required", data_dir, ready=False, has_data=True)
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", MagicMock()), \
             pytest.raises(SystemExit) as exc:
            sync_mod.main()
        assert exc.value.code == 1
        mod.sync.assert_not_called()
        # Must have retried the configured number of attempts
        assert mod.wait_until_ready.call_count == sync_mod.REACHABILITY_ATTEMPTS

    def test_sync_error_exits_nonzero(self, data_dir):
        """A module whose sync() raises fails the run — not a silent warn."""
        mod = _make_mod("broken", data_dir, ready=True, has_data=True)
        mod.sync.side_effect = RuntimeError("API down")
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", MagicMock()), \
             pytest.raises(SystemExit) as exc:
            sync_mod.main()
        assert exc.value.code == 1

    def test_retry_recovers_from_transient_unreachability(self, data_dir):
        """A module that becomes reachable on a later attempt must sync successfully."""
        mod = _make_mod("slow", data_dir, has_data=True)
        # Unreachable on first 2 attempts, reachable on 3rd
        mod.wait_until_ready.side_effect = [False, False, True]
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", MagicMock()):
            sync_mod.main()  # no SystemExit
        mod.sync.assert_called_once()
        assert mod.wait_until_ready.call_count == 3

    def test_mix_of_ready_and_required_unreachable_still_fails(self, data_dir):
        ready = _make_mod("ready", data_dir, ready=True, has_data=True)
        missing = _make_mod("missing", data_dir, ready=False, has_data=True)
        with patch.object(sync_mod, "discover_modules", return_value=[ready, missing]), \
             patch.object(sync_mod, "SYNC_MARKER", MagicMock()), \
             pytest.raises(SystemExit) as exc:
            sync_mod.main()
        assert exc.value.code == 1
        ready.sync.assert_called_once()
        missing.sync.assert_not_called()

    def test_marker_written_even_on_failure(self, data_dir):
        """Export loop-prevention marker writes regardless of sync outcome."""
        mod = _make_mod("broken", data_dir, ready=False, has_data=True)
        marker = MagicMock()
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", marker), \
             pytest.raises(SystemExit):
            sync_mod.main()
        marker.touch.assert_called_once()


class TestExportMarkerCheck:
    def test_recent_marker_skips_export(self):
        marker = MagicMock()
        marker.exists.return_value = True
        marker.stat.return_value.st_mtime = time.time() - 60  # 1 min ago

        with patch.object(export_mod, 'SYNC_MARKER', marker):
            with patch.object(export_mod, 'git') as mock_git:
                mock_git.return_value = MagicMock(returncode=0)
                export_mod.git_commit_and_push()
                commit_calls = [c for c in mock_git.call_args_list if c[0][0] == 'commit']
                assert len(commit_calls) == 0

    def test_old_marker_allows_export(self):
        marker = MagicMock()
        marker.exists.return_value = True
        marker.stat.return_value.st_mtime = time.time() - 600  # 10 min ago

        with patch.object(export_mod, 'SYNC_MARKER', marker):
            with patch.object(export_mod, 'git') as mock_git:
                mock_git.return_value = MagicMock(returncode=0)
                export_mod.git_commit_and_push()
                add_calls = [c for c in mock_git.call_args_list if c[0][0] == 'add']
                assert len(add_calls) >= 1

    def test_no_marker_allows_export(self):
        marker = MagicMock()
        marker.exists.return_value = False

        with patch.object(export_mod, 'SYNC_MARKER', marker):
            with patch.object(export_mod, 'git') as mock_git:
                mock_git.return_value = MagicMock(returncode=0)
                export_mod.git_commit_and_push()
                add_calls = [c for c in mock_git.call_args_list if c[0][0] == 'add']
                assert len(add_calls) >= 1


class TestExportReadEnvKeys:
    """read_env_keys parses .env into *_API_KEY env vars, honoring quotes/comments."""

    @staticmethod
    def _write(repo_dir, text):
        (repo_dir / ".env").write_text(text)

    def test_strips_quotes_and_inline_comments(self, tmp_path, monkeypatch):
        monkeypatch.setattr(export_mod, "REPO_DIR", tmp_path)
        for k in ("FOO_API_KEY", "BAR_API_KEY", "BAZ_API_KEY", "QUX_API_KEY", "PLAIN_API_KEY"):
            monkeypatch.delenv(k, raising=False)
        self._write(tmp_path, (
            "# header\n"
            "FOO_API_KEY=\"double\"\n"
            "BAR_API_KEY='single'\n"
            "BAZ_API_KEY=value # comment\n"
            "QUX_API_KEY=abc#123\n"   # '#' with no preceding space stays part of the value
            "PLAIN_API_KEY=bare\n"
        ))
        export_mod.read_env_keys()
        assert os.environ["FOO_API_KEY"] == "double"
        assert os.environ["BAR_API_KEY"] == "single"
        assert os.environ["BAZ_API_KEY"] == "value"
        assert os.environ["QUX_API_KEY"] == "abc#123"
        assert os.environ["PLAIN_API_KEY"] == "bare"

    def test_only_sets_api_key_vars(self, tmp_path, monkeypatch):
        monkeypatch.setattr(export_mod, "REPO_DIR", tmp_path)
        monkeypatch.delenv("OTHER_VAR", raising=False)
        self._write(tmp_path, "OTHER_VAR=ignored\nREAL_API_KEY=ok\n")
        export_mod.read_env_keys()
        assert "OTHER_VAR" not in os.environ
        assert os.environ["REAL_API_KEY"] == "ok"

    def test_does_not_override_existing(self, tmp_path, monkeypatch):
        monkeypatch.setattr(export_mod, "REPO_DIR", tmp_path)
        monkeypatch.setenv("EXISTING_API_KEY", "from-shell")
        self._write(tmp_path, "EXISTING_API_KEY=from-file\n")
        export_mod.read_env_keys()
        assert os.environ["EXISTING_API_KEY"] == "from-shell"

    def test_missing_env_file_is_noop(self, tmp_path, monkeypatch):
        monkeypatch.setattr(export_mod, "REPO_DIR", tmp_path)
        monkeypatch.delenv("NONE_API_KEY", raising=False)
        export_mod.read_env_keys()  # no .env present — must not raise
        assert "NONE_API_KEY" not in os.environ


class TestExportDryRunCompare:
    def test_reports_changed_and_new(self, tmp_path, monkeypatch, capsys):
        data_dir = tmp_path / "data"
        monkeypatch.setattr(export_mod, "DATA_DIR", data_dir)
        (data_dir / "radarr").mkdir(parents=True)
        (data_dir / "radarr" / "changed.json").write_text('{"v": 1}')
        (data_dir / "radarr" / "same.json").write_text('{"v": 1}')

        tmp_export = tmp_path / "export"
        (tmp_export / "radarr").mkdir(parents=True)
        (tmp_export / "radarr" / "changed.json").write_text('{"v": 2}')
        (tmp_export / "radarr" / "same.json").write_text('{"v": 1}')
        (tmp_export / "radarr" / "new.json").write_text('{}')

        export_mod.dry_run_compare(tmp_export)
        out = capsys.readouterr().out
        assert "CHANGED: radarr/changed.json" in out
        assert "NEW: radarr/new.json" in out
        assert "radarr/same.json" not in out

    def test_reports_no_changes_when_identical(self, tmp_path, monkeypatch, capsys):
        data_dir = tmp_path / "data"
        monkeypatch.setattr(export_mod, "DATA_DIR", data_dir)
        (data_dir / "svc").mkdir(parents=True)
        (data_dir / "svc" / "x.json").write_text('{}')

        tmp_export = tmp_path / "export"
        (tmp_export / "svc").mkdir(parents=True)
        (tmp_export / "svc" / "x.json").write_text('{}')

        export_mod.dry_run_compare(tmp_export)
        assert "no changes detected" in capsys.readouterr().out


class TestExportDiscoverAndExport:
    def test_exports_reachable_skips_unreachable_continues_on_error(self, tmp_path, capsys):
        good = MagicMock()
        good.name = "good"
        good.is_reachable.return_value = True
        down = MagicMock()
        down.name = "down"
        down.is_reachable.return_value = False
        broken = MagicMock()
        broken.name = "broken"
        broken.is_reachable.return_value = True
        broken.export.side_effect = RuntimeError("kaboom")

        with patch.object(export_mod, "discover_modules", return_value=[good, down, broken]):
            export_mod.discover_and_export(tmp_path)  # must not raise on broken.export

        good.export.assert_called_once()
        down.export.assert_not_called()
        broken.export.assert_called_once()
        out = capsys.readouterr().out
        assert "down: not reachable" in out
        assert "ERROR exporting broken" in out
