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
    """
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


def main(argv: list[str] | None = None) -> int:
    # Stub — will be expanded in later tasks
    print("chunker CLI not yet implemented", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
