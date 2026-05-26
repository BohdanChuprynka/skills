"""Tests for scripts/chunker.py — parsing, greedy bucketing, min/max enforcement, hard-max fail."""

import json
import subprocess
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
    """Each chunk should either stay <= target, OR contain exactly one block
    (the case where a single block alone exceeds target — we don't split blocks).
    """
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    target = 20
    chunks = chunker.greedy_bucket(blocks, target_tokens=target)
    for c in chunks:
        tokens = sum(count_tokens_for_block(b) for b in c)
        assert tokens <= target or len(c) == 1, (
            f"chunk has {tokens} tokens (> target {target}) AND {len(c)} blocks "
            f"(should be 1 for no-split overflow)"
        )


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


def test_greedy_bucket_rejects_invalid_target():
    """target_tokens must be >= 1; 0 and negative should raise ValueError."""
    with pytest.raises(ValueError, match=r"target_tokens"):
        chunker.greedy_bucket([], target_tokens=0)
    with pytest.raises(ValueError, match=r"target_tokens"):
        chunker.greedy_bucket([], target_tokens=-1)


# Helper used in tests above:
def count_tokens_for_block(block):
    from count_tokens import count
    n, _ = count(block.text)
    return n


def test_apply_bounds_enforces_min_chunks(fixtures_dir: Path):
    """When count is below min, the LARGEST (by tokens) chunk gets split."""
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=10_000_000)  # 1 chunk
    pre_tokens = sum(count_tokens_for_block(b) for b in chunks[0])

    bounded = chunker.apply_bounds(chunks, min_chunks=2, max_chunks=8, hard_max=10_000_000)
    assert len(bounded) == 2

    # The single original chunk was split — total tokens preserved across the two new chunks
    post_tokens = sum(count_tokens_for_block(b) for c in bounded for b in c)
    assert post_tokens == pre_tokens

    # Sanity: each output chunk has at least one block
    assert all(len(c) >= 1 for c in bounded)


def test_apply_bounds_enforces_max_chunks(fixtures_dir: Path):
    """When count is above max, smallest adjacent pair gets merged."""
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=1)  # one block per chunk = 8 chunks
    pre_count = len(chunks)
    pre_token_total = sum(count_tokens_for_block(b) for c in chunks for b in c)

    bounded = chunker.apply_bounds(chunks, min_chunks=2, max_chunks=3, hard_max=10_000_000)
    assert len(bounded) == 3
    assert pre_count > 3  # sanity: we actually merged

    # Total tokens preserved across merge
    post_token_total = sum(count_tokens_for_block(b) for c in bounded for b in c)
    assert post_token_total == pre_token_total

    # All blocks accounted for
    assert sum(len(c) for c in bounded) == sum(len(c) for c in chunks)


def test_apply_bounds_splits_the_largest_chunk_when_below_min(fixtures_dir: Path):
    """Verify the split-largest selection: a 3-chunk input where chunk[1] is the largest
    by tokens should see chunk[1] split (not chunk[0] or chunk[2])."""
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)

    # Hand-craft 3 chunks where the middle one is largest:
    # take chunks of sizes 1, 5, 2 blocks (middle has most blocks => most tokens given roughly equal block sizes)
    assert len(blocks) >= 8  # sanity on fixture
    handcrafted = [blocks[0:1], blocks[1:6], blocks[6:8]]

    bounded = chunker.apply_bounds(handcrafted, min_chunks=4, max_chunks=8, hard_max=10_000_000)
    assert len(bounded) == 4

    # The first and last chunks should be unchanged (length 1 and 2 respectively).
    # The middle chunk (originally 5 blocks) should have been split.
    assert len(bounded[0]) == 1
    # bounded[-1] is the trailing original chunk
    assert bounded[-1] == handcrafted[-1]


def test_apply_bounds_preserves_chronological_order(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=1)
    bounded = chunker.apply_bounds(chunks, min_chunks=2, max_chunks=3, hard_max=10_000_000)
    flat = [b for c in bounded for b in c]
    assert [b.start_ts for b in flat] == sorted([b.start_ts for b in flat])


def test_apply_bounds_passthrough_when_in_range(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=50)
    if 2 <= len(chunks) <= 8:
        bounded = chunker.apply_bounds(chunks, min_chunks=2, max_chunks=8, hard_max=10_000_000)
        assert len(bounded) == len(chunks)


def test_apply_bounds_raises_when_any_chunk_exceeds_hard_max(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=10_000_000)
    with pytest.raises(ValueError, match=r"hard-max"):
        chunker.apply_bounds(chunks, min_chunks=1, max_chunks=1, hard_max=5)


def test_apply_bounds_rejects_invalid_bounds(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=50)
    with pytest.raises(ValueError, match=r"min_chunks and max_chunks"):
        chunker.apply_bounds(chunks, min_chunks=0, max_chunks=8, hard_max=10_000_000)
    with pytest.raises(ValueError, match=r"max_chunks .+ must be >= min_chunks"):
        chunker.apply_bounds(chunks, min_chunks=5, max_chunks=2, hard_max=10_000_000)


def test_cli_writes_chunk_files_and_meta(tmp_path: Path, fixtures_dir: Path):
    out_dir = tmp_path / "chunks"
    script = Path(__file__).resolve().parent.parent / "scripts" / "chunker.py"

    result = subprocess.run(
        [
            "python3", str(script),
            "--input", str(fixtures_dir / "sessions-medium.md"),
            "--output-dir", str(out_dir),
            "--target-tokens", "50",
            "--min", "2",
            "--max", "8",
            "--hard-max", "10000000",
        ],
        capture_output=True, text=True, check=True,
    )

    chunk_files = sorted(out_dir.glob("chunk-*.md"))
    assert len(chunk_files) >= 2
    assert (out_dir / "chunks-meta.json").exists()

    meta = json.loads((out_dir / "chunks-meta.json").read_text())
    assert "chunks" in meta
    assert "total_chunks" in meta
    assert meta["total_chunks"] == len(chunk_files)
    assert len(meta["chunks"]) == len(chunk_files)
    for entry in meta["chunks"]:
        for key in ("chunk_id", "start", "end", "token_count", "session_count"):
            assert key in entry


def test_cli_chunk_files_contain_session_headers(tmp_path: Path, fixtures_dir: Path):
    out_dir = tmp_path / "chunks"
    script = Path(__file__).resolve().parent.parent / "scripts" / "chunker.py"
    subprocess.run(
        ["python3", str(script),
         "--input", str(fixtures_dir / "sessions-medium.md"),
         "--output-dir", str(out_dir),
         "--target-tokens", "100"],
        check=True, capture_output=True, text=True,
    )
    for chunk_file in sorted(out_dir.glob("chunk-*.md")):
        text = chunk_file.read_text(encoding="utf-8")
        assert "--- claude" in text or "--- codex" in text


def test_cli_exits_nonzero_on_hard_max_violation(tmp_path: Path, fixtures_dir: Path):
    out_dir = tmp_path / "chunks"
    script = Path(__file__).resolve().parent.parent / "scripts" / "chunker.py"
    result = subprocess.run(
        ["python3", str(script),
         "--input", str(fixtures_dir / "sessions-medium.md"),
         "--output-dir", str(out_dir),
         "--target-tokens", "10000000",
         "--hard-max", "5",
         "--max", "1", "--min", "1"],
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert "hard-max" in result.stderr
    # No partial output should have been written
    assert not list(out_dir.glob("chunk-*.md"))
