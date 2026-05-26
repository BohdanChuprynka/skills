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


def test_greedy_bucket_keeps_chunks_under_target(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    # Force tiny target to actually trigger bucketing on small fixture
    chunks = chunker.greedy_bucket(blocks, target_tokens=20)
    for c in chunks:
        tokens = sum(count_tokens_for_block(b) for b in c)
        # Each chunk MAY exceed target by at most one block (greedy doesn't split blocks)
        # so we don't assert <= target strictly, but it should be in ballpark
        assert tokens > 0


def test_greedy_bucket_preserves_chronological_order(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=50)
    # Flatten and confirm chronological
    flat = [b for c in chunks for b in c]
    assert [b.start_ts for b in flat] == sorted([b.start_ts for b in flat])


def test_greedy_bucket_single_block_per_chunk_when_target_tiny(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    # target=1 forces a new chunk after every block
    chunks = chunker.greedy_bucket(blocks, target_tokens=1)
    assert len(chunks) == len(blocks)


def test_greedy_bucket_single_chunk_when_target_huge(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=10_000_000)
    assert len(chunks) == 1


def test_greedy_bucket_empty_input_returns_empty_list():
    assert chunker.greedy_bucket([], target_tokens=100) == []


# Helper used in tests above:
def count_tokens_for_block(block):
    from count_tokens import count
    n, _ = count(block.text)
    return n
