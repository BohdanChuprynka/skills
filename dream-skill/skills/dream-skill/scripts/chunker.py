#!/usr/bin/env python3
"""chunker.py — split a preprocess.py sessions.md file into N chunks by greedy token-bucketing.

Each output chunk:
- preserves session-header lines verbatim (citation rule depends on this)
- contains an integer number of complete session blocks (no straddling)
- targets ~150K tokens (configurable)
- is sorted chronologically by start timestamp

Fails up-front if any chunk would exceed --hard-max tokens; refuses to write
files in that case.

CLI usage:
    python3 chunker.py --input sessions.md --output-dir $TMP/chunks/ \
        --target-tokens 150000 [--min 2] [--max 8] [--hard-max 180000]
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path

# Make count_tokens importable when run from CLI or imported.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from count_tokens import count as count_tokens


SESSION_HEADER = re.compile(
    r"^---\s+(?P<source>claude|codex)\s+(?P<date>\d{4}-\d{2}-\d{2})\s+(?P<time>\d{2}:\d{2})\s+---\s*$"
)


@dataclass
class Block:
    source: str
    start_ts: datetime
    text: str  # starts with the '--- ... ---' header line


def parse_sessions(content: str) -> list[Block]:
    """Parse a sessions.md file into chronologically-ordered Block objects."""
    blocks: list[Block] = []
    current_lines: list[str] = []
    current_meta: tuple[str, datetime] | None = None

    def flush():
        if current_meta is not None and current_lines:
            source, ts = current_meta
            blocks.append(Block(source=source, start_ts=ts, text="\n".join(current_lines)))

    for raw_line in content.splitlines():
        match = SESSION_HEADER.match(raw_line)
        if match:
            flush()
            current_lines = [raw_line]
            ts = datetime.fromisoformat(f"{match['date']} {match['time']}:00")
            current_meta = (match["source"], ts)
        elif current_meta is None:
            # Preamble (file comment header before first session) — skip.
            continue
        else:
            current_lines.append(raw_line)
    flush()

    blocks.sort(key=lambda b: b.start_ts)
    return blocks


def greedy_bucket(blocks: list[Block], target_tokens: int) -> list[list[Block]]:
    """Greedy chronological bucketing.

    Walks blocks in order, accumulating into the current chunk until adding the
    next block would push its total over `target_tokens`. At that point, closes
    the current chunk and starts a new one.

    Never splits a block across chunks (so a single very-large block may produce
    a chunk that exceeds target; the hard-max check in apply_bounds() catches
    this).

    Raises ValueError if target_tokens < 1.
    """
    if target_tokens < 1:
        raise ValueError(f"target_tokens must be >= 1, got {target_tokens}")
    if not blocks:
        return []

    chunks: list[list[Block]] = [[]]
    current_tokens = 0

    for block in blocks:
        block_tokens, _ = count_tokens(block.text)
        if chunks[-1] and current_tokens + block_tokens > target_tokens:
            chunks.append([])
            current_tokens = 0
        chunks[-1].append(block)
        current_tokens += block_tokens

    # No empty-tail cleanup needed: the loop always appends the block before
    # opening a new chunk, so the last chunk always contains at least one block.
    return chunks


def _chunk_tokens(chunk: list[Block]) -> int:
    n, _ = count_tokens("\n".join(b.text for b in chunk))
    return n


def apply_bounds(
    chunks: list[list[Block]],
    *,
    min_chunks: int,
    max_chunks: int,
    hard_max: int,
) -> list[list[Block]]:
    """Adjust chunk count into [min_chunks, max_chunks] and verify hard-max.

    - If under min: repeatedly split the largest chunk in half (preserving
      chronological order) until count reaches min, or until no chunk has
      more than 1 block (cannot split further).
    - If over max: repeatedly merge the smallest adjacent pair until count
      reaches max.
    - After bounds, raise ValueError if any chunk exceeds hard_max tokens.
    """
    if min_chunks < 1 or max_chunks < 1:
        raise ValueError(f"min_chunks and max_chunks must be >= 1, got {min_chunks}/{max_chunks}")
    if max_chunks < min_chunks:
        raise ValueError(f"max_chunks ({max_chunks}) must be >= min_chunks ({min_chunks})")

    chunks = [list(c) for c in chunks]  # defensive copy

    # Split until min
    while len(chunks) < min_chunks:
        # Find largest chunk that has >= 2 blocks
        candidates = [(i, _chunk_tokens(c)) for i, c in enumerate(chunks) if len(c) >= 2]
        if not candidates:
            break  # cannot split further
        idx, _ = max(candidates, key=lambda x: x[1])
        c = chunks[idx]
        mid = len(c) // 2
        chunks[idx] = c[:mid]
        chunks.insert(idx + 1, c[mid:])

    # Merge until max
    while len(chunks) > max_chunks:
        # Find smallest adjacent pair (smallest combined size)
        pair_idx = min(
            range(len(chunks) - 1),
            key=lambda i: _chunk_tokens(chunks[i]) + _chunk_tokens(chunks[i + 1]),
        )
        chunks[pair_idx] = chunks[pair_idx] + chunks[pair_idx + 1]
        del chunks[pair_idx + 1]

    # Hard-max check (post-bounds)
    for i, c in enumerate(chunks):
        n = _chunk_tokens(c)
        if n > hard_max:
            raise ValueError(
                f"chunker: chunk {i + 1} would have {n} tokens (> hard-max {hard_max}); "
                "narrow --since or wait for a release that supports oversized windows"
            )

    return chunks


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Split sessions.md into N chunks via greedy token-bucketing.")
    ap.add_argument("--input", required=True, help="Path to sessions.md")
    ap.add_argument("--output-dir", required=True, help="Directory to write chunk-N.md files into")
    ap.add_argument("--target-tokens", type=int, default=150_000)
    ap.add_argument("--min", dest="min_chunks", type=int, default=2)
    ap.add_argument("--max", dest="max_chunks", type=int, default=8)
    ap.add_argument("--hard-max", type=int, default=180_000)
    args = ap.parse_args(argv)

    input_path = Path(args.input)
    try:
        content = input_path.read_text(encoding="utf-8", errors="ignore")
    except (FileNotFoundError, IsADirectoryError) as e:
        print(f"chunker: cannot read {input_path}: {e}", file=sys.stderr)
        return 1
    blocks = parse_sessions(content)
    if not blocks:
        print("chunker: no session blocks found in input", file=sys.stderr)
        return 1

    chunks = greedy_bucket(blocks, target_tokens=args.target_tokens)
    try:
        chunks = apply_bounds(
            chunks,
            min_chunks=args.min_chunks,
            max_chunks=args.max_chunks,
            hard_max=args.hard_max,
        )
    except ValueError as e:
        print(f"chunker: {e}", file=sys.stderr)
        return 2

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Clear stale chunk-*.md files from previous runs. Preserve any unrelated files.
    for stale in out_dir.glob("chunk-*.md"):
        stale.unlink()
    # Also clear stale chunks-meta.json to avoid mixing schemas
    meta_path = out_dir / "chunks-meta.json"
    if meta_path.exists():
        meta_path.unlink()

    meta_chunks = []
    for i, chunk in enumerate(chunks, 1):
        body = "\n".join(b.text for b in chunk) + "\n"
        (out_dir / f"chunk-{i}.md").write_text(body, encoding="utf-8")
        n_tokens, _ = count_tokens(body)
        meta_chunks.append({
            "chunk_id": i,
            "start": chunk[0].start_ts.isoformat(),
            "end": chunk[-1].start_ts.isoformat(),
            "token_count": n_tokens,
            "session_count": len(chunk),
        })

    meta = {"chunks": meta_chunks, "total_chunks": len(chunks)}
    (out_dir / "chunks-meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

    # Human-readable summary to stdout
    print(f"chunker: wrote {len(chunks)} chunks to {out_dir}")
    for entry in meta_chunks:
        print(
            f"  chunk-{entry['chunk_id']}.md: {entry['session_count']} sessions, "
            f"{entry['token_count']} tokens, {entry['start']} -> {entry['end']}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
