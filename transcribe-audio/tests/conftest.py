"""Shared pytest fixtures."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

FIXTURES_DIR = Path(__file__).parent / "fixtures"


@pytest.fixture(scope="session")
def short_test_mp3(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Generate a 3-second silent MP3 fixture if not already cached.

    Uses ffmpeg's lavfi anullsrc filter. Skips the test session if ffmpeg is missing.
    """
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    cached = FIXTURES_DIR / "short_test.mp3"
    if cached.exists():
        return cached

    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg required to generate test fixture")

    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=16000:cl=mono",
            "-t",
            "3",
            "-b:a",
            "64k",
            "-loglevel",
            "error",
            str(cached),
        ],
        check=True,
    )
    return cached


@pytest.fixture
def fake_openai_key(monkeypatch: pytest.MonkeyPatch) -> str:
    """Inject a fake OPENAI_API_KEY into the env for the duration of a test."""
    key = "sk-test-fake-key-for-unit-tests"
    monkeypatch.setenv("OPENAI_API_KEY", key)
    return key


@pytest.fixture(autouse=True)
def isolated_home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    """Redirect HOME + XDG_CONFIG_HOME to a tmp dir so tests can't touch real config."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home / ".config"))
    return home
