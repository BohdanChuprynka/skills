"""Tests for CLI wiring (Typer app)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from typer.testing import CliRunner

from transcribe_audio.cli import _resolve_summary_style, app
from transcribe_audio.config import Config, write_config

runner = CliRunner()


def test_resolve_summary_style_falls_back_to_config(fake_openai_key: str) -> None:
    cfg = Config(openai_api_key=fake_openai_key, default_summary_style="detailed")
    # Flag omitted → config default; flag given → flag wins.
    assert _resolve_summary_style(None, cfg) == "detailed"
    assert _resolve_summary_style("action_items", cfg) == "action_items"


def test_summarize_command_honors_config_default_style(
    fake_openai_key: str, tmp_path: Path
) -> None:
    """End-to-end: `summarize` with no --style uses default_summary_style from config."""
    write_config({"default_summary_style": "detailed"})
    transcript = tmp_path / "t.txt"
    transcript.write_text("hello world", encoding="utf-8")

    captured: dict[str, str] = {}

    def fake_summarize(text: str, config: Config, style: str = "brief", **_: object) -> MagicMock:
        captured["style"] = style
        return MagicMock(text="SUMMARY")

    with patch("transcribe_audio.cli.summarize_text", side_effect=fake_summarize):
        result = runner.invoke(app, ["summarize", str(transcript)])

    assert result.exit_code == 0, result.output
    assert captured["style"] == "detailed"
