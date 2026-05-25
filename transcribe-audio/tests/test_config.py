"""Tests for layered config loader."""

from __future__ import annotations

from pathlib import Path

import pytest

from transcribe_audio.config import load_config, write_config


def test_load_config_requires_api_key(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    # No .env in cwd
    monkeypatch.chdir(tmp_path)
    with pytest.raises(RuntimeError, match="OPENAI_API_KEY"):
        load_config()


def test_load_config_from_env(fake_openai_key: str) -> None:
    config = load_config()
    assert config.openai_api_key == fake_openai_key
    assert config.transcribe_model == "whisper-1"
    assert config.default_language == "auto"


def test_load_config_merges_yaml_with_env(
    fake_openai_key: str,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # write_config respects XDG_CONFIG_HOME via the isolated_home autouse fixture
    write_config(
        {
            "transcribe_model": "whisper-1",
            "default_language": "uk",
            "default_summary_style": "detailed",
        }
    )
    config = load_config()
    assert config.openai_api_key == fake_openai_key
    assert config.default_language == "uk"
    assert config.default_summary_style == "detailed"


def test_write_config_strips_api_key(fake_openai_key: str, tmp_path: Path) -> None:
    path = write_config({"openai_api_key": "sk-leaked", "default_language": "en"})
    content = path.read_text()
    assert "sk-leaked" not in content
    assert "openai_api_key" not in content
    assert "default_language: en" in content
