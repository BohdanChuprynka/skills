"""Tests for scripts/chunker.py — parsing, greedy bucketing, min/max enforcement, hard-max fail."""

from datetime import datetime
from pathlib import Path

import pytest

import chunker


def test_parse_sessions_returns_blocks(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-tiny.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    assert len(blocks) == 3


def test_parse_sessions_extracts_source_and_timestamp(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-tiny.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    assert blocks[0].source == "claude"
    assert blocks[0].start_ts == datetime.fromisoformat("2026-05-19 13:24:00")
    assert blocks[2].source == "codex"


def test_parse_sessions_preserves_header_in_block_text(fixtures_dir: Path):
    """Each block's text MUST start with its own '--- <source> ... ---' header so
    the citation rule in map-system.md can extract source references verbatim."""
    content = (fixtures_dir / "sessions-tiny.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    for block in blocks:
        first_line = block.text.splitlines()[0]
        assert first_line.startswith("--- "), f"block text must start with header line, got {first_line!r}"


def test_parse_sessions_returns_blocks_in_chronological_order(fixtures_dir: Path):
    """Even if the source file isn't sorted, parser must sort by start_ts."""
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    timestamps = [b.start_ts for b in blocks]
    assert timestamps == sorted(timestamps)


def test_parse_sessions_skips_preamble(fixtures_dir: Path):
    """The '# Local conversation transcript ...' comment block before any --- header
    must NOT appear in any returned block's text."""
    content = (fixtures_dir / "sessions-tiny.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    for block in blocks:
        assert "# Local conversation transcript" not in block.text


def test_parse_sessions_empty_string_returns_empty_list():
    assert chunker.parse_sessions("") == []
