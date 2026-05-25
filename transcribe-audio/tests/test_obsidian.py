"""Tests for Obsidian note writer."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from transcribe_audio.config import Config
from transcribe_audio.obsidian import slugify, write_obsidian_note
from transcribe_audio.summarize import SummaryResult
from transcribe_audio.transcribe import Segment, TranscriptionResult


def test_slugify_handles_english() -> None:
    assert slugify("Team Standup Notes") == "team-standup-notes"


def test_slugify_handles_ukrainian_cyrillic() -> None:
    out = slugify("Розмова про онтології")
    # Cyrillic should be preserved (we kept the Cyrillic range in the regex).
    assert "розмова" in out
    assert "про" in out


def test_slugify_truncates_long_input() -> None:
    long = "word " * 50
    assert len(slugify(long, max_len=20)) <= 20


def test_slugify_empty_input_returns_untitled() -> None:
    assert slugify("") == "untitled"
    assert slugify("   ") == "untitled"


def _make_transcription(tmp_path: Path) -> TranscriptionResult:
    source = tmp_path / "call.mp3"
    source.touch()
    return TranscriptionResult(
        text="Привіт, як справи. Ми обговорюємо knowledge graphs.",
        segments=[
            Segment(start=0.0, end=2.5, text="Привіт, як справи."),
            Segment(start=2.5, end=6.0, text="Ми обговорюємо knowledge graphs."),
        ],
        language="uk",
        duration=6.0,
        source_path=source,
    )


def test_write_obsidian_note_writes_frontmatter_and_body(
    fake_openai_key: str, tmp_path: Path
) -> None:
    vault = tmp_path / "vault"
    vault.mkdir()
    config = Config(
        openai_api_key=fake_openai_key,
        vault_path=vault,
    )
    transcription = _make_transcription(tmp_path)
    summary = SummaryResult(text="**Topic:** test call.", style="brief", model="gpt-4o-mini")

    out_path = write_obsidian_note(transcription, summary, config, title="Test Call")

    assert out_path.exists()
    assert out_path.parent == vault / "inbox"
    text = out_path.read_text(encoding="utf-8")

    # Frontmatter block
    assert text.startswith("---\n")
    fm_block = text.split("---\n", 2)[1]
    fm = yaml.safe_load(fm_block)
    assert fm["type"] == "transcript"
    assert fm["language"] == "uk"
    assert fm["duration_seconds"] == 6.0
    assert fm["summary_style"] == "brief"
    assert fm["status"] == "unreviewed"

    # Body
    assert "# Test Call" in text
    assert "Привіт, як справи" in text
    assert "**Topic:** test call." in text


def test_write_obsidian_note_without_summary(fake_openai_key: str, tmp_path: Path) -> None:
    vault = tmp_path / "vault"
    vault.mkdir()
    config = Config(openai_api_key=fake_openai_key, vault_path=vault)
    transcription = _make_transcription(tmp_path)

    out_path = write_obsidian_note(transcription, None, config, title="No Summary")
    text = out_path.read_text(encoding="utf-8")

    assert "## Summary" not in text
    assert "## Transcript" in text


def test_write_obsidian_note_errors_when_vault_unset(
    fake_openai_key: str, tmp_path: Path
) -> None:
    config = Config(openai_api_key=fake_openai_key, vault_path=None)
    transcription = _make_transcription(tmp_path)
    with pytest.raises(ValueError, match="vault_path not set"):
        write_obsidian_note(transcription, None, config)
