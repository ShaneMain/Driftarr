"""Tests for sync.py and export.py entry points."""

import pathlib
import time
import pytest
from unittest.mock import patch, MagicMock

import configs.sync.sync as sync_mod
import configs.sync.export as export_mod


class TestSyncDiscovery:
    def test_discovers_modules(self, data_dir):
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
    def test_calls_sync_on_ready_modules(self):
        mock_mod = MagicMock()
        mock_mod.name = "test"
        mock_mod.url = "http://x"
        mock_mod.data_dir = pathlib.Path("/tmp/fake")
        mock_mod.wait_until_ready.return_value = True

        with patch.object(sync_mod, 'discover_modules', return_value=[mock_mod]):
            with patch.object(sync_mod, 'SYNC_MARKER', MagicMock()):
                sync_mod.main()

        mock_mod.wait_until_ready.assert_called_once()
        mock_mod.sync.assert_called_once()

    def test_skips_unreachable_modules(self):
        ready = MagicMock(name="ready", wait_until_ready=MagicMock(return_value=True))
        ready.name = "ready"
        ready.url = "http://x"
        ready.data_dir = pathlib.Path("/tmp/fake")

        unreachable = MagicMock(name="down", wait_until_ready=MagicMock(return_value=False))
        unreachable.name = "down"
        unreachable.url = "http://x"
        unreachable.data_dir = pathlib.Path("/tmp/fake")

        with patch.object(sync_mod, 'discover_modules', return_value=[unreachable, ready]):
            with patch.object(sync_mod, 'SYNC_MARKER', MagicMock()):
                sync_mod.main()

        unreachable.sync.assert_not_called()
        ready.sync.assert_called_once()

    def test_writes_marker(self):
        marker = MagicMock()
        with patch.object(sync_mod, 'discover_modules', return_value=[]):
            with patch.object(sync_mod, 'SYNC_MARKER', marker):
                sync_mod.main()
        marker.touch.assert_called_once()

    def test_sync_error_does_not_crash(self):
        mock_mod = MagicMock()
        mock_mod.name = "broken"
        mock_mod.url = "http://x"
        mock_mod.data_dir = pathlib.Path("/tmp/fake")
        mock_mod.wait_until_ready.return_value = True
        mock_mod.sync.side_effect = RuntimeError("API down")

        with patch.object(sync_mod, 'discover_modules', return_value=[mock_mod]):
            with patch.object(sync_mod, 'SYNC_MARKER', MagicMock()):
                sync_mod.main()  # Should not raise


class TestExportMarkerCheck:
    def test_recent_marker_skips_export(self):
        marker = MagicMock()
        marker.exists.return_value = True
        marker.stat.return_value.st_mtime = time.time() - 60  # 1 min ago

        with patch.object(export_mod, 'SYNC_MARKER', marker):
            with patch.object(export_mod, 'git') as mock_git:
                mock_git.return_value = MagicMock(returncode=0)
                export_mod.git_commit_and_push()
                # Should not reach git commit
                commit_calls = [c for c in mock_git.call_args_list if c[0][0] == 'commit']
                assert len(commit_calls) == 0

    def test_old_marker_allows_export(self):
        marker = MagicMock()
        marker.exists.return_value = True
        marker.stat.return_value.st_mtime = time.time() - 600  # 10 min ago

        with patch.object(export_mod, 'SYNC_MARKER', marker):
            with patch.object(export_mod, 'git') as mock_git:
                # Simulate no changes
                mock_git.return_value = MagicMock(returncode=0)
                export_mod.git_commit_and_push()
                # Should reach git add at minimum
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
