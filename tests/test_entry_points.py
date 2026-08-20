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


class TestSyncMarkerLocation:
    """H1: sync.py (in-container) and export.py (host) must agree on the
    marker path, and it must live under the bind-mounted data dir."""

    def test_marker_lives_in_data_dir_on_both_sides(self):
        assert sync_mod.SYNC_MARKER == sync_mod.DATA_DIR / ".sync-ran"
        assert export_mod.SYNC_MARKER == export_mod.DATA_DIR / ".sync-ran"
        assert sync_mod.SYNC_MARKER.relative_to(sync_mod.DATA_DIR) == \
            export_mod.SYNC_MARKER.relative_to(export_mod.DATA_DIR)

    def test_marker_is_gitignored(self):
        root = export_mod.pathlib.Path(__file__).resolve().parents[1]
        assert "configs/data/.sync-ran" in (root / ".gitignore").read_text().split()

    def test_diff_mode_does_not_touch_marker(self, data_dir):
        mod = _make_mod("ok", data_dir)
        marker = MagicMock()
        with patch.object(sync_mod, "discover_modules", return_value=[mod]), \
             patch.object(sync_mod, "SYNC_MARKER", marker), \
             patch.object(sync_mod.sys, "argv", ["sync", "diff"]):
            sync_mod.main()
        marker.touch.assert_not_called()


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

    def test_loads_every_key_not_just_api_keys(self, tmp_path, monkeypatch):
        """M3: modules reference JELLYSEERR_KEY, NZBGET_CONTROL_PASS, ... too."""
        monkeypatch.setattr(export_mod, "REPO_DIR", tmp_path)
        for k in ("JELLYSEERR_KEY", "NZBGET_CONTROL_PASS", "REAL_API_KEY", "EXPORTED_VAR"):
            monkeypatch.delenv(k, raising=False)
        self._write(tmp_path, "JELLYSEERR_KEY=j\nNZBGET_CONTROL_PASS=p\nREAL_API_KEY=ok\nexport EXPORTED_VAR=e\n")
        export_mod.read_env_keys()
        assert os.environ["JELLYSEERR_KEY"] == "j"
        assert os.environ["NZBGET_CONTROL_PASS"] == "p"
        assert os.environ["REAL_API_KEY"] == "ok"
        assert os.environ["EXPORTED_VAR"] == "e"

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
            failed = export_mod.discover_and_export(tmp_path)  # must not raise on broken.export
        assert failed == ["broken"]

        good.export.assert_called_once()
        down.export.assert_not_called()
        broken.export.assert_called_once()
        out = capsys.readouterr().out
        assert "down: not reachable" in out
        assert "ERROR exporting broken" in out


class TestExportMainMarkerFirst:
    """Marker must be checked before any file is written, else a skipped
    commit leaves the worktree dirty for the next deploy."""

    def test_fresh_marker_exits_before_exporting(self, tmp_path, monkeypatch, capsys):
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        marker = data_dir / ".sync-ran"
        marker.touch()
        monkeypatch.setattr(export_mod, "DRY_RUN", False)
        monkeypatch.setattr(export_mod, "DATA_DIR", data_dir)
        monkeypatch.setattr(export_mod, "SYNC_MARKER", marker)
        with patch.object(export_mod, "read_env_keys"), \
             patch.object(export_mod, "discover_and_export") as export, \
             patch.object(export_mod, "git") as git:
            export_mod.main()
        export.assert_not_called()
        git.assert_not_called()
        assert sorted(p.name for p in data_dir.iterdir()) == [".sync-ran"]
        assert "skipping export to avoid loop" in capsys.readouterr().out

    def test_old_marker_proceeds(self, tmp_path, monkeypatch):
        data_dir = tmp_path / "data"
        data_dir.mkdir()
        marker = data_dir / ".sync-ran"
        marker.touch()
        os.utime(marker, (time.time() - 600, time.time() - 600))
        monkeypatch.setattr(export_mod, "DRY_RUN", False)
        monkeypatch.setattr(export_mod, "SYNC_MARKER", marker)
        with patch.object(export_mod, "read_env_keys"), \
             patch.object(export_mod, "discover_and_export", return_value=[]) as export, \
             patch.object(export_mod, "git_commit_and_push") as commit:
            export_mod.main()
        export.assert_called_once()
        commit.assert_called_once()


class TestExportMainPartialFailure:
    """M1: a module that raised mid-export leaves a fresh/stale mix — don't commit it."""

    def test_failed_export_skips_commit_and_exits_nonzero(self, monkeypatch):
        monkeypatch.setattr(export_mod, "DRY_RUN", False)
        with patch.object(export_mod, "read_env_keys"), \
             patch.object(export_mod, "discover_and_export", return_value=["radarr"]), \
             patch.object(export_mod, "git_commit_and_push") as commit, \
             patch.object(export_mod, "git") as git, \
             pytest.raises(SystemExit):
            export_mod.main()
        commit.assert_not_called()
        assert ("checkout", "--", "configs/data/") in [c[0] for c in git.call_args_list]

    def test_clean_export_commits(self, monkeypatch):
        monkeypatch.setattr(export_mod, "DRY_RUN", False)
        with patch.object(export_mod, "read_env_keys"), \
             patch.object(export_mod, "discover_and_export", return_value=[]), \
             patch.object(export_mod, "git_commit_and_push") as commit:
            export_mod.main()
        commit.assert_called_once()
