"""Shared pytest fixtures for config sync module tests."""

import json
import os
import pathlib
import tempfile
import pytest
from unittest.mock import patch, MagicMock

from configs.sync.base import AppModule
from configs.sync.modules.radarr import RadarrModule
from configs.sync.modules.sonarr import SonarrModule
from configs.sync.modules.qbittorrent import QbittorrentModule


@pytest.fixture
def data_dir(tmp_path):
    """Temporary data directory for module file I/O."""
    d = tmp_path / "data"
    d.mkdir()
    return d


@pytest.fixture
def radarr(data_dir):
    """RadarrModule pointed at a temp data dir with mocked env."""
    with patch.dict(os.environ, {"RADARR_URL": "http://localhost:7878", "RADARR_API_KEY": "testkey"}):
        return RadarrModule(data_dir=data_dir, mode="sync")


@pytest.fixture
def radarr_diff(data_dir):
    """RadarrModule in diff (dry-run) mode."""
    with patch.dict(os.environ, {"RADARR_URL": "http://localhost:7878", "RADARR_API_KEY": "testkey"}):
        return RadarrModule(data_dir=data_dir, mode="diff")


@pytest.fixture
def sonarr(data_dir):
    """SonarrModule pointed at a temp data dir with mocked env."""
    with patch.dict(os.environ, {"SONARR_URL": "http://localhost:8989", "SONARR_API_KEY": "testkey"}):
        return SonarrModule(data_dir=data_dir, mode="sync")


@pytest.fixture
def qbittorrent(data_dir):
    """QbittorrentModule pointed at a temp data dir with mocked env."""
    with patch.dict(os.environ, {"QBITTORRENT_URL": "http://localhost:8080"}):
        return QbittorrentModule(data_dir=data_dir, mode="sync")
