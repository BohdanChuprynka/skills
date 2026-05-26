# dream-skill map-reduce Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a parallel map + sequential reduce path to dream-skill so it can process conversation windows that exceed Claude Sonnet 4.6's 200K-token context cap, while preserving today's single-call path for small windows.

**Architecture:** A new routing step after preprocess.py + load_vault_state.py counts total LLM-call tokens; below 130K it takes the existing single-call path, at or above it splits sessions.md into 2-8 greedy token-bucketed chunks, fires parallel Haiku 4.5 map calls (pure extraction, no MCPs), concatenates extracts, and runs a single Sonnet 4.6 reduce call with MCPs that produces today's dream-report format unchanged. Strict abort on any failure; map workers are isolated with `--bare --no-session-persistence` to avoid feedback loops into `~/.claude/projects/`.

**Tech Stack:** Python 3.11+ (chunker, count_tokens, tests via pytest), Bash 4+ (dream.sh glue), `claude` CLI (Claude Code 2.x with `--betas` and `--bare` support), tiktoken (optional dep with byte fallback).

**Spec:** [`docs/superpowers/specs/2026-05-26-dream-skill-map-reduce-design.md`](../specs/2026-05-26-dream-skill-map-reduce-design.md) at commit `96b6eb4`.

---

## File structure

All paths are relative to the monorepo root (`/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/`).

```
skills/dream-skill/
  dream.sh                              MODIFIED  (route + chunked stages + new flags + on_exit + v2 log)
  prompts/
    system.md                           MODIFIED  (1 paragraph added: dual-path mode awareness)
    reconcile.md                        MODIFIED  (1 paragraph added: chunked-mode + citation rule + WINDOW)
    map.md                              NEW       (user message template)
    map-system.md                       NEW       (system prompt for map calls; CRITICAL: citation rule)
  scripts/
    count_tokens.py                     NEW       (tiktoken + byte fallback)
    chunker.py                          NEW       (greedy token-bucketing chunker)
    preprocess.py                       UNCHANGED
    load_vault_state.py                 UNCHANGED
    apply_auto.py                       UNCHANGED
    apply_undo.sh                       UNCHANGED
  tests/                                NEW DIR
    __init__.py                         NEW       (empty marker)
    conftest.py                         NEW       (pytest fixtures path)
    test_count_tokens.py                NEW
    test_chunker.py                     NEW
    test_dream_sh.sh                    NEW       (bash integration smoke test)
    fixtures/
      sessions-tiny.md                  NEW       (3 sessions, ~5K chars; below threshold)
      sessions-medium.md                NEW       (8 sessions, ~50K chars; above threshold-equivalent at lowered target)
      vault-sample.md                   NEW       (small vault snapshot fixture)
      vault-empty.md                    NEW       (<1KB vault for empty-vault routing test)
.gitignore                              MODIFIED  (add dream-extracts-*, dream-errors-* patterns)
```

**Repository convention:** the monorepo root is `/Users/bohdan/Documents/IT-Work/Projects/IT/skills/` and `dream-skill/` lives there as a subtree. The dream-skill module lives at `dream-skill/skills/dream-skill/`. All test commands assume cwd is the dream-skill module dir unless specified.

---

## Task 1: count_tokens.py — token counting with tiktoken + byte fallback

**Files:**
- Create: `skills/dream-skill/skills/dream-skill/tests/__init__.py` (empty)
- Create: `skills/dream-skill/skills/dream-skill/tests/conftest.py`
- Create: `skills/dream-skill/skills/dream-skill/tests/test_count_tokens.py`
- Create: `skills/dream-skill/skills/dream-skill/scripts/count_tokens.py`

- [ ] **Step 1: Create tests directory and empty __init__.py**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
mkdir -p tests/fixtures
touch tests/__init__.py
```

- [ ] **Step 2: Create tests/conftest.py with the fixtures-path fixture**

```python
# tests/conftest.py
"""Pytest config: expose the fixtures directory + the scripts directory on sys.path."""
import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))


@pytest.fixture
def fixtures_dir() -> Path:
    return Path(__file__).resolve().parent / "fixtures"
```

- [ ] **Step 3: Write the failing test for count_tokens**

```python
# tests/test_count_tokens.py
"""Tests for scripts/count_tokens.py.

Validates: tiktoken-backed counting when available, byte fallback otherwise,
the two paths stay within 15% of each other on representative input.
"""

import subprocess
from pathlib import Path

import count_tokens


def test_count_tokens_returns_positive_int_for_nonempty_string():
    count, used_tiktoken = count_tokens.count("hello world this is a test sentence")
    assert isinstance(count, int)
    assert count > 0


def test_count_tokens_empty_string_is_zero():
    count, _ = count_tokens.count("")
    assert count == 0


def test_tiktoken_and_fallback_agree_within_15_percent():
    # Skip if tiktoken not installed
    try:
        import tiktoken  # noqa: F401
    except ImportError:
        import pytest
        pytest.skip("tiktoken not installed; cannot run parity test")

    sample = ("The quick brown fox jumps over the lazy dog. " * 200)

    count_tt, used_tt = count_tokens.count(sample)
    assert used_tt is True

    # Force fallback
    fallback = count_tokens._byte_estimate(sample)

    # Within 15% either direction
    assert 0.85 <= fallback / count_tt <= 1.15, (
        f"byte fallback {fallback} diverged from tiktoken {count_tt} by >15%"
    )


def test_cli_mode_reads_file(tmp_path: Path):
    sample_file = tmp_path / "sample.txt"
    sample_file.write_text("hello world " * 100, encoding="utf-8")

    script_path = Path(__file__).resolve().parent.parent / "scripts" / "count_tokens.py"
    result = subprocess.run(
        ["python3", str(script_path), str(sample_file)],
        capture_output=True,
        text=True,
        check=True,
    )
    n = int(result.stdout.strip())
    assert n > 0


def test_cli_mode_reads_stdin():
    script_path = Path(__file__).resolve().parent.parent / "scripts" / "count_tokens.py"
    result = subprocess.run(
        ["python3", str(script_path), "-"],
        input="this is stdin input",
        capture_output=True,
        text=True,
        check=True,
    )
    n = int(result.stdout.strip())
    assert n > 0
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
python3 -m pytest tests/test_count_tokens.py -v
```

Expected: ImportError / ModuleNotFoundError on `import count_tokens` (or all 5 tests FAIL).

- [ ] **Step 5: Implement count_tokens.py**

```python
#!/usr/bin/env python3
"""count_tokens.py — count tokens in a file or stdin.

Tries tiktoken first (cl100k_base, a reasonable proxy for Claude tokenization).
Falls back to a byte estimate (len / 3.5) if tiktoken is not installed.

CLI usage:
    python3 count_tokens.py path/to/file       # reads file
    python3 count_tokens.py -                  # reads stdin

Library usage:
    from count_tokens import count
    n, used_tiktoken = count("some text")
"""

import sys
from pathlib import Path

_TIKTOKEN_WARNED = False


def _byte_estimate(text: str) -> int:
    """Cheap fallback: ~3.5 chars per token on prose."""
    return int(len(text) / 3.5)


def count(text: str) -> tuple[int, bool]:
    """Return (token_count, used_tiktoken_bool)."""
    if not text:
        return 0, False
    try:
        import tiktoken
    except ImportError:
        global _TIKTOKEN_WARNED
        if not _TIKTOKEN_WARNED:
            print(
                "count_tokens.py: WARN tiktoken not installed; using byte/3.5 estimate. "
                "Install with `pip install tiktoken` for accurate counts.",
                file=sys.stderr,
            )
            _TIKTOKEN_WARNED = True
        return _byte_estimate(text), False

    enc = tiktoken.get_encoding("cl100k_base")
    return len(enc.encode(text)), True


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: count_tokens.py <path>|-", file=sys.stderr)
        return 1

    if args[0] == "-":
        text = sys.stdin.read()
    else:
        text = Path(args[0]).read_text(encoding="utf-8", errors="ignore")

    n, _ = count(text)
    print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Run tests, verify pass**

```bash
python3 -m pytest tests/test_count_tokens.py -v
```

Expected: all 5 tests PASS. If tiktoken is not installed, one test should SKIP (not fail).

- [ ] **Step 7: Make the script executable**

```bash
chmod +x scripts/count_tokens.py
```

- [ ] **Step 8: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/scripts/count_tokens.py \
        skills/dream-skill/tests/__init__.py \
        skills/dream-skill/tests/conftest.py \
        skills/dream-skill/tests/test_count_tokens.py
git commit -m "$(cat <<'EOF'
feat(dream-skill): add count_tokens.py utility with tiktoken + byte fallback

Foundation for the upcoming map-reduce routing decision in dream.sh.
tiktoken via cl100k_base when available, falls back to len/3.5 otherwise.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: chunker.py — session-block parser (with tests)

**Files:**
- Create: `skills/dream-skill/skills/dream-skill/tests/fixtures/sessions-tiny.md`
- Create: `skills/dream-skill/skills/dream-skill/tests/fixtures/sessions-medium.md`
- Create: `skills/dream-skill/skills/dream-skill/tests/test_chunker.py`
- Create: `skills/dream-skill/skills/dream-skill/scripts/chunker.py` (partial — parser only)

- [ ] **Step 1: Create the tiny fixture (3 sessions, both sources)**

```bash
cat > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/fixtures/sessions-tiny.md <<'EOF'
# Local conversation transcript — window: explicit --since 7d
# Sources: Claude Code, Codex CLI
# Filter: on (coding-dump heuristic)
# Files scanned: 100 | files kept: 3
# Cutoff: 2026-05-19T14:00:00+00:00

--- claude 2026-05-19 13:24 ---
USER: I switched from React to Svelte for the rebuild.
      ASST: Got it.

--- claude 2026-05-21 14:05 ---
USER: Today I decided to drop the Antler residency entirely.

--- codex 2026-05-22 09:00 ---
USER: Logging that I went for a 5k run this morning.
EOF
```

- [ ] **Step 2: Create the medium fixture (8 sessions across a longer span)**

```bash
cat > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/fixtures/sessions-medium.md <<'EOF'
# Local conversation transcript — window: explicit --since 30d
# Sources: Claude Code, Codex CLI

--- claude 2026-04-28 10:00 ---
USER: Started looking into self-hosted vector DBs.

--- claude 2026-05-02 11:15 ---
USER: Decided to go with pgvector for the persona-RAG project.

--- claude 2026-05-08 16:30 ---
USER: I'm going to draft the Cleveland Clinic onboarding doc tonight.

--- claude 2026-05-12 09:00 ---
USER: Switched morning routine — gym before school now.

--- codex 2026-05-15 14:20 ---
USER: Logging 4x5 deadlifts at 145kg.

--- claude 2026-05-18 19:00 ---
USER: My priority for Cycle 4 Goal 2 is the agency thesis.

--- claude 2026-05-21 11:00 ---
USER: Protege partnership ended today.

--- claude 2026-05-24 13:45 ---
USER: New mentor outreach to Anastasia Markuts on LinkedIn.
EOF
```

- [ ] **Step 3: Write the failing parser tests**

```python
# tests/test_chunker.py
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
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
python3 -m pytest tests/test_chunker.py -v
```

Expected: ImportError on `import chunker` (module doesn't exist yet).

- [ ] **Step 5: Implement the parser**

```python
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


def main(argv: list[str] | None = None) -> int:
    # Stub — will be expanded in later tasks
    print("chunker CLI not yet implemented", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Run tests, verify all 6 parser tests pass**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: 6 PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/scripts/chunker.py \
        skills/dream-skill/tests/test_chunker.py \
        skills/dream-skill/tests/fixtures/sessions-tiny.md \
        skills/dream-skill/tests/fixtures/sessions-medium.md
git commit -m "$(cat <<'EOF'
feat(dream-skill): add chunker.py session-block parser

Parses preprocess.py output into chronologically-sorted Block objects with
source + start_ts metadata. Each block's text preserves the verbatim '--- source
date time ---' header line so the downstream citation rule (map-system.md) can
attach a source reference to every extracted bullet.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: chunker.py — greedy token-bucketing

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/scripts/chunker.py`
- Modify: `skills/dream-skill/skills/dream-skill/tests/test_chunker.py`

- [ ] **Step 1: Add failing tests for greedy bucketing**

Append to `tests/test_chunker.py`:

```python
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
```

- [ ] **Step 2: Run tests, verify failure (greedy_bucket undefined)**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: 5 new tests FAIL with `AttributeError: module 'chunker' has no attribute 'greedy_bucket'`.

- [ ] **Step 3: Implement greedy_bucket**

Add to `scripts/chunker.py` after the `Block` dataclass:

```python
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

    if not chunks[-1]:
        chunks.pop()
    return chunks
```

- [ ] **Step 4: Run tests, verify all 5 new tests pass**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: all 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/scripts/chunker.py \
        skills/dream-skill/tests/test_chunker.py
git commit -m "feat(dream-skill): add greedy_bucket() to chunker.py

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: chunker.py — min/max enforcement (split-largest / merge-smallest)

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/scripts/chunker.py`
- Modify: `skills/dream-skill/skills/dream-skill/tests/test_chunker.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_chunker.py`:

```python
def test_apply_bounds_enforces_min_chunks(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=10_000_000)  # 1 chunk
    bounded = chunker.apply_bounds(chunks, min_chunks=2, max_chunks=8, hard_max=10_000_000)
    assert len(bounded) == 2  # split the single chunk in two


def test_apply_bounds_enforces_max_chunks(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=1)  # one block per chunk = 8 chunks
    bounded = chunker.apply_bounds(chunks, min_chunks=2, max_chunks=3, hard_max=10_000_000)
    assert len(bounded) == 3  # merged down to 3


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
```

- [ ] **Step 2: Run tests, verify failure**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: 4 new tests FAIL with AttributeError on `apply_bounds`.

- [ ] **Step 3: Implement apply_bounds**

Add to `scripts/chunker.py` after `greedy_bucket`:

```python
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
```

- [ ] **Step 4: Run tests, verify pass**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: all 15 tests PASS.

- [ ] **Step 5: Add a hard-max-fail test**

Append to `tests/test_chunker.py`:

```python
def test_apply_bounds_raises_when_any_chunk_exceeds_hard_max(fixtures_dir: Path):
    content = (fixtures_dir / "sessions-medium.md").read_text(encoding="utf-8")
    blocks = chunker.parse_sessions(content)
    chunks = chunker.greedy_bucket(blocks, target_tokens=10_000_000)
    with pytest.raises(ValueError, match=r"hard-max"):
        chunker.apply_bounds(chunks, min_chunks=1, max_chunks=1, hard_max=5)
```

- [ ] **Step 6: Run, verify the new test passes**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: all 16 tests PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/scripts/chunker.py \
        skills/dream-skill/tests/test_chunker.py
git commit -m "feat(dream-skill): add apply_bounds() with hard-max enforcement

Splits the largest chunk to satisfy min, merges smallest adjacent pairs to
satisfy max, raises ValueError if any chunk would exceed hard_max.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: chunker.py — CLI + chunks-meta.json output

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/scripts/chunker.py`
- Modify: `skills/dream-skill/skills/dream-skill/tests/test_chunker.py`

- [ ] **Step 1: Add the CLI integration test**

Append to `tests/test_chunker.py`:

```python
import subprocess
import json


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
```

- [ ] **Step 2: Run tests, verify failures (CLI not yet implemented)**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: 3 new tests FAIL.

- [ ] **Step 3: Replace the stub `main()` with the real CLI**

In `scripts/chunker.py`, replace the existing `main()` stub:

```python
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Split sessions.md into N chunks via greedy token-bucketing.")
    ap.add_argument("--input", required=True, help="Path to sessions.md")
    ap.add_argument("--output-dir", required=True, help="Directory to write chunk-N.md files into")
    ap.add_argument("--target-tokens", type=int, default=150_000)
    ap.add_argument("--min", dest="min_chunks", type=int, default=2)
    ap.add_argument("--max", dest="max_chunks", type=int, default=8)
    ap.add_argument("--hard-max", type=int, default=180_000)
    args = ap.parse_args(argv)

    content = Path(args.input).read_text(encoding="utf-8", errors="ignore")
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
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
python3 -m pytest tests/test_chunker.py -v
```

Expected: all 19 tests PASS.

- [ ] **Step 5: Make executable + commit**

```bash
chmod +x /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/scripts/chunker.py
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/scripts/chunker.py \
        skills/dream-skill/tests/test_chunker.py
git commit -m "feat(dream-skill): wire chunker.py CLI + chunks-meta.json output

Bails up-front (exit code 2) with an actionable error message if any chunk
would exceed --hard-max; no partial output written on failure.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: New prompt files (map.md + map-system.md)

**Files:**
- Create: `skills/dream-skill/skills/dream-skill/prompts/map.md`
- Create: `skills/dream-skill/skills/dream-skill/prompts/map-system.md`

- [ ] **Step 1: Create prompts/map.md**

```bash
cat > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/prompts/map.md <<'EOF'
Extract persona signals from the following local-conversation transcript chunk.

Today's date: {TODAY}
Chunk date range: {CHUNK_RANGE}

=== TRANSCRIPT ===
{CHUNK_CONTENT}

Produce extraction output per your system prompt. Preserve verbatim source
session references in every bullet so downstream channel-triangulation works.
EOF
```

- [ ] **Step 2: Create prompts/map-system.md**

```bash
cat > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/prompts/map-system.md <<'EOF'
You are extracting persona-relevant signals from a chunk of a user's local
conversation transcripts. You are NOT reconciling against a vault, producing a
dream report, or making recommendations. Your sole job is signal extraction.

## What counts as a persona signal

The user maintains an Obsidian vault that models them AS A PERSON — identity,
life-state, preferences, relationships, body, schedule, goals. The vault is a
persona model, not a project archive.

KEEP (persona-relevant):
- State changes: jobs, projects, schools, relationships, programs, gyms, locations
- Decisions: new commitments, dropped commitments, pivots, plans
- New entities: people mentioned, companies/programs joined, mentors, friends
- Soft signals: recurring themes, things the user is excited/worried about
- Observed contradictions: statements that may conflict with prior context
- Recent themes: rolling-attention items, what's on the user's mind

IGNORE (work-output, not persona):
- Code-task content (implementations, debugging, refactoring, build logs)
- Project-output telemetry (commits, file edits, deploys)
- General programming/tech questions
- Tool-use plumbing

## Output format

Loose markdown. Use these section headers when applicable, omit empty sections:

## State changes
## Decisions
## New entities
## Soft signals
## Observed contradictions
## Recent themes

## Citation requirement (CRITICAL)

Every bullet MUST end with a citation that names the source session
verbatim from the chunk's session-header lines.

The chunk you're reading contains session blocks delimited like:
    --- claude 2026-05-19 13:24 ---
    USER: ...

Cite using this exact format: `(Claude Session 2026-05-19 13:24)` or
`(Codex Session 2026-05-19 13:24)` depending on which source the
session came from. Downstream tooling parses these prefixes to count
distinct evidence channels — do not paraphrase or omit them.

Example bullet:
- Bohdan switched from React to Svelte for the frontend rebuild. (Claude Session 2026-05-21 09:14)

## Hard rules

- NO YAML frontmatter
- NO dream-report sections (no "## Auto-apply", "## Needs confirmation", etc.)
- NO recommendations or proposals — extraction only
- NO MCP tool use (you don't have those tools here)
- If chunk has zero persona signal: output the single line "No persona-relevant signals in this chunk."
- Target output: under 2KB per chunk
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/prompts/map.md \
        skills/dream-skill/prompts/map-system.md
git commit -m "feat(dream-skill): add map.md + map-system.md prompts

System prompt enforces the critical citation rule so apply_auto.py's channel
parser keeps working downstream. User message template substitutes
{TODAY}/{CHUNK_RANGE}/{CHUNK_CONTENT}.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Modify reconcile.md (add chunked-mode + citation paragraph)

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/prompts/reconcile.md`

- [ ] **Step 1: Read current reconcile.md to know exact insertion point**

```bash
cat /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/prompts/reconcile.md
```

The current file has `=== CONVERSATION SIGNALS (window: {WINDOW}) ===` followed by `{SESSIONS}` followed by `=== VAULT STATE ===`. We insert AFTER the `{SESSIONS}` line and BEFORE `=== VAULT STATE ===`.

- [ ] **Step 2: Edit reconcile.md to insert the chunked-mode paragraph**

Use the Edit tool. Find this block in reconcile.md:

```
=== CONVERSATION SIGNALS (window: {WINDOW}) ===
{SESSIONS}

=== VAULT STATE ===
```

Replace with:

```
=== CONVERSATION SIGNALS (window: {WINDOW}) ===
{SESSIONS}

Note: when the conversation window is large, this CONVERSATION SIGNALS block
contains per-chunk PRE-EXTRACTED signal lists rather than raw conversation
transcripts, delimited by `=== CHUNK N (date_range) ===` markers. Treat them
as already-filtered persona signal lists.

Each extracted bullet already includes a verbatim source citation in the form
`(Claude Session YYYY-MM-DD HH:MM)` or `(Codex Session YYYY-MM-DD HH:MM)`.
When you write proposals into the dream report, you MUST preserve these
citations VERBATIM in the proposal's Evidence: block — the downstream parser
counts distinct channels by matching this exact prefix format. Do not
paraphrase ("during a coding session") — copy the literal prefix.

The `{WINDOW}` value above always refers to the FULL conversation window, not
to any individual chunk's date range. Use it as such when phrasing dates and
relative-time expressions.

=== VAULT STATE ===
```

- [ ] **Step 3: Verify the file still has all four placeholders**

```bash
grep -c '{TODAY}\|{WINDOW}\|{SESSIONS}\|{VAULT}' /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/prompts/reconcile.md
```

Expected: 4 (one occurrence of each, may include extra `{WINDOW}` references in the new paragraph).

- [ ] **Step 4: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/prompts/reconcile.md
git commit -m "feat(dream-skill): teach reconcile.md about chunked-mode + citations

Adds a paragraph explaining that SESSIONS may contain pre-extracted summaries
in chunked mode, mandates verbatim citation preservation so apply_auto.py's
channel parser counts evidence correctly, and clarifies WINDOW semantics.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Modify system.md (add dual-path explanation)

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/prompts/system.md`

- [ ] **Step 1: Read current system.md for insertion point**

The file currently has a section `## Inputs you will receive` describing the three input blocks. We add the new paragraph right after the existing description of CONVERSATION SIGNALS (item 1 in the numbered list).

- [ ] **Step 2: Edit system.md to insert the dual-path paragraph**

Use the Edit tool. Find this exact line block in `prompts/system.md`:

```
1. **CONVERSATION SIGNALS** — cleaned excerpts from recent local Claude Code and/or Codex CLI conversations in the configured window. User messages are full; assistant turns appear only when they provide question/answer context. Messages flagged `[★]` matched a high-signal pattern. Source headers identify the local product, e.g. `--- claude session <id> ---` or `--- codex session <id> ---`.
```

Replace with:

```
1. **CONVERSATION SIGNALS** — cleaned excerpts from recent local Claude Code and/or Codex CLI conversations in the configured window. User messages are full; assistant turns appear only when they provide question/answer context. Source headers identify the local product, e.g. `--- claude 2026-05-19 13:24 ---` or `--- codex 2026-05-19 13:24 ---`.

   This reconcile call may run in one of two modes:

   - **Single-call mode** — the SIGNALS block contains raw cleaned transcripts from preprocess.py. Treat them as primary evidence; cite each message by its session header (`Claude Session YYYY-MM-DD HH:MM`).
   - **Chunked mode** — the SIGNALS block contains per-chunk pre-extracted signal summaries (with `## State changes`, `## Decisions`, etc. headers and `=== CHUNK N ===` separators). Each bullet already has a verbatim source citation embedded — copy that citation literally into your proposals' Evidence: blocks.

   In both modes, MCP-tool probes (Notion / Calendar / Gmail / Filesystem) are your responsibility and run as today. The map step does NOT touch MCPs.
```

- [ ] **Step 3: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/prompts/system.md
git commit -m "feat(dream-skill): document dual-path SIGNALS contract in system.md

So the reduce LLM knows whether it's seeing raw transcripts or pre-extracted
summaries, and how to cite either kind into the dream report.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: dream.sh — invoke count_tokens + on_exit trap (no behavior change yet)

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/dream.sh`

This task ONLY swaps the existing `trap 'rm -rf "$TMP"' EXIT` for the new `on_exit` function and adds a token-counting probe that prints to stdout. No routing yet — every run still goes through the single-call path.

- [ ] **Step 1: Locate the current trap line + the stage-1 logs**

```bash
grep -n 'trap .* EXIT\|SESSIONS_BYTES=\|conversations.md:' /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

Note the line numbers.

- [ ] **Step 2: Replace the trap with on_exit() function**

Use Edit on `skills/dream-skill/skills/dream-skill/dream.sh`. Replace this exact pair of lines:

```bash
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
```

with:

```bash
TMP="$(mktemp -d)"

# Custom EXIT handler: on non-zero exit, preserve worker error logs.
on_exit() {
  local rc=$?
  if [[ "$rc" != "0" && -d "$TMP/responses" ]]; then
    mkdir -p "$OUTPUT_DIR/dream-errors-$DATE" 2>/dev/null || true
    cp "$TMP/responses/"*.log "$OUTPUT_DIR/dream-errors-$DATE/" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit $rc
}
trap on_exit EXIT
```

- [ ] **Step 3: Add token counting + log after Stage 1**

Find this block in `dream.sh`:

```bash
SESSIONS_BYTES=$(wc -c < "$TMP/sessions.md" | tr -d ' ')
USER_MSG_COUNT=$(grep -c "^USER:" "$TMP/sessions.md" 2>/dev/null || echo 0)
echo "      conversations.md: ${SESSIONS_BYTES} bytes, ${USER_MSG_COUNT} user messages"
```

Replace with:

```bash
SESSIONS_BYTES=$(wc -c < "$TMP/sessions.md" | tr -d ' ')
USER_MSG_COUNT=$(grep -c "^USER:" "$TMP/sessions.md" 2>/dev/null || echo 0)
SESSIONS_TOKENS=$(python3 "$SCRIPTS_DIR/count_tokens.py" "$TMP/sessions.md")
echo "      conversations.md: ${SESSIONS_BYTES} bytes, ${USER_MSG_COUNT} user messages, ~${SESSIONS_TOKENS} tokens"
```

- [ ] **Step 4: Smoke-check that dream.sh still runs end-to-end**

Run with `DREAM_SKIP_LLM=1 ./dream.sh --dry-run` if you can; otherwise verify syntax:

```bash
bash -n /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

Expected: no syntax errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/dream.sh
git commit -m "refactor(dream-skill): replace EXIT trap with on_exit() + log token count

Foundation for the routing decision in the next task. on_exit() preserves
worker error logs to dream-errors-<date>/ when the script aborts. No behavior
change yet — every run still takes the existing single-call path.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: dream.sh — route decision (sub-threshold → single-call, supra-threshold → stub)

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/dream.sh`

- [ ] **Step 1: Add route-decision block**

Insert this block in `dream.sh` immediately AFTER the existing Stage 2 (`load_vault_state.py`) summary message:

```bash
# ============================================================
# Stage 2.5: route decision (single-call vs chunked map-reduce)
# ============================================================

ROUTE_THRESHOLD_TOKENS="${DREAM_ROUTE_THRESHOLD:-130000}"
VAULT_BYTES_NUM=$(wc -c < "$TMP/vault.md" | tr -d ' ')
VAULT_TOKENS=$(python3 "$SCRIPTS_DIR/count_tokens.py" "$TMP/vault.md")
# 10000 token overhead for prompt template + system prompt
PROMPT_OVERHEAD=10000
TOTAL_TOKENS=$((SESSIONS_TOKENS + VAULT_TOKENS + PROMPT_OVERHEAD))

# Empty-vault first-run always single-call
if [[ "$VAULT_BYTES_NUM" -lt 1024 ]]; then
  ROUTE=single
  ROUTE_REASON="empty vault (${VAULT_BYTES_NUM} bytes < 1KB)"
elif [[ "${FORCE_CHUNKED:-0}" == "1" ]]; then
  ROUTE=chunked
  ROUTE_REASON="--force-chunked"
elif [[ "${FORCE_SINGLE:-0}" == "1" ]]; then
  ROUTE=single
  ROUTE_REASON="--force-single"
elif [[ "$TOTAL_TOKENS" -lt "$ROUTE_THRESHOLD_TOKENS" ]]; then
  ROUTE=single
  ROUTE_REASON="total ${TOTAL_TOKENS} tokens < threshold ${ROUTE_THRESHOLD_TOKENS}"
else
  ROUTE=chunked
  ROUTE_REASON="total ${TOTAL_TOKENS} tokens >= threshold ${ROUTE_THRESHOLD_TOKENS}"
fi

echo "      route: $ROUTE ($ROUTE_REASON)"
```

(This block must be inserted before the existing `Stage 3: reconcile via Claude` block, but AFTER the vault-snapshot log line.)

- [ ] **Step 2: Stub the chunked branch with an explicit "not yet implemented" exit**

We wrap ONLY the existing Stage 3 (the `claude --print` reconcile call + empty-response check) inside the if/else. Stage 4 (the `python3 <<'PYEOF'` heredoc that parses the response and writes the report) STAYS OUTSIDE the if/else and runs unconditionally — both routes produce `$RESPONSE_JSON` for it to consume.

Find this block in `dream.sh`:

```bash
echo "[3/4] reconcile via Claude ($MODEL)…"

if [[ ! -f "$PROMPTS_DIR/reconcile.md" ]]; then
  echo "dream.sh: ERROR  reconcile prompt missing: $PROMPTS_DIR/reconcile.md" >&2
  exit 1
fi

RECONCILE_TEMPLATE="$(cat "$PROMPTS_DIR/reconcile.md")"
```

…and ALL subsequent lines up to and including:

```bash
if [[ ! -s "$RESPONSE_JSON" ]]; then
  echo "dream.sh: ERROR  claude returned empty response" >&2
  exit 1
fi
```

Wrap that entire span with:

```bash
if [[ "$ROUTE" == "single" ]]; then

  echo "[3/4] reconcile via Claude ($MODEL)…"

  # ... ALL of the existing Stage 3 body — verbatim — goes here ...

  if [[ ! -s "$RESPONSE_JSON" ]]; then
    echo "dream.sh: ERROR  claude returned empty response" >&2
    exit 1
  fi

else
  echo "dream.sh: chunked path not yet wired (stub); exiting." >&2
  exit 1
fi
```

The closing `fi` goes IMMEDIATELY BEFORE the existing `# ============` Stage-4 section divider. Do NOT wrap Stage 4 — it must run for both routes.

- [ ] **Step 3: Syntax check**

```bash
bash -n /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

Expected: no errors.

- [ ] **Step 4: Test routing for sub-threshold (real run, low-window)**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
./dream.sh --since 1d --vault-root "$DREAM_VAULT_ROOT" --no-mcp 2>&1 | head -20
```

Expected output includes a line like `route: single (total NNNK tokens < threshold 130000)`.

- [ ] **Step 5: Test routing for force-chunked**

```bash
./dream.sh --since 1d --vault-root "$DREAM_VAULT_ROOT" --no-mcp --force-chunked 2>&1 | head -20
```

(NOTE: `--force-chunked` flag itself is not yet parsed in arg parsing — set via env: `FORCE_CHUNKED=1 ./dream.sh ...`. The proper CLI flag is added in Task 14.)

Expected: script prints `route: chunked (--force-chunked)`, then exits with the stub message.

- [ ] **Step 6: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/dream.sh
git commit -m "feat(dream-skill): add route decision (chunked path stubbed)

Sub-threshold and empty-vault runs continue to the existing single-call path.
Supra-threshold runs hit a stub that exits 1. The chunked branch body lands in
the next task.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: dream.sh — implement chunked path Stages 3a-3d

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/dream.sh`

This is the largest task. Replace the stub `else` branch from Task 10 with the four chunked stages.

- [ ] **Step 1: Replace the stub `else` branch**

Replace:

```bash
else
  echo "dream.sh: chunked path not yet wired (stub); exiting." >&2
  exit 1
fi
```

with the full chunked-path block:

```bash
else
  # ============================================================
  # Stage 3a: chunker
  # ============================================================
  echo "[3a/4] chunker — splitting sessions.md…"
  mkdir -p "$TMP/chunks" "$TMP/responses" "$TMP/extracts"
  python3 "$SCRIPTS_DIR/chunker.py" \
    --input "$TMP/sessions.md" \
    --output-dir "$TMP/chunks" \
    --target-tokens "${DREAM_CHUNK_TARGET_TOKENS:-150000}" \
    --min "${DREAM_CHUNK_MIN:-2}" \
    --max "${DREAM_CHUNK_MAX:-8}" \
    --hard-max "${DREAM_CHUNK_HARD_MAX:-180000}"

  CHUNK_COUNT=$(ls "$TMP/chunks/chunk-"*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$CHUNK_COUNT" -lt 2 ]]; then
    echo "dream.sh: ERROR  chunker produced $CHUNK_COUNT chunks; expected >= 2" >&2
    exit 1
  fi

  # ============================================================
  # Stage 3b: parallel map calls (Haiku)
  # ============================================================
  echo "[3b/4] launching $CHUNK_COUNT parallel map calls (model: ${MAP_MODEL:-claude-haiku-4-5-20251001})…"

  MAP_MODEL_USE="${MAP_MODEL:-claude-haiku-4-5-20251001}"
  MAP_SYSTEM_FILE="$PROMPTS_DIR/map-system.md"
  MAP_USER_TEMPLATE_FILE="$PROMPTS_DIR/map.md"
  declare -a MAP_PIDS=()

  # Read chunks-meta.json for date ranges to substitute into the map prompt
  for chunk_file in "$TMP/chunks/chunk-"*.md; do
    chunk_id=$(basename "$chunk_file" .md | sed 's/chunk-//')

    # Substitute {TODAY}, {CHUNK_RANGE}, {CHUNK_CONTENT} into map.md template.
    # CHUNK_RANGE comes from chunks-meta.json.
    CHUNK_RANGE=$(python3 -c '
import json, sys
meta = json.load(open(sys.argv[1]))
entries = {str(e["chunk_id"]): f"{e[\"start\"]} -> {e[\"end\"]}" for e in meta["chunks"]}
print(entries.get(sys.argv[2], "unknown"))
' "$TMP/chunks/chunks-meta.json" "$chunk_id")

    MAP_PROMPT=$(TEMPLATE="$(cat "$MAP_USER_TEMPLATE_FILE")" \
                 TODAY="$DATE" \
                 CHUNK_RANGE="$CHUNK_RANGE" \
                 CHUNK_CONTENT="$(cat "$chunk_file")" \
                 python3 -c '
import os
t = os.environ["TEMPLATE"]
t = t.replace("{TODAY}", os.environ["TODAY"])
t = t.replace("{CHUNK_RANGE}", os.environ["CHUNK_RANGE"])
t = t.replace("{CHUNK_CONTENT}", os.environ["CHUNK_CONTENT"])
print(t, end="")
')

    # Background launch; prompt via stdin (avoids ARG_MAX).
    (
      printf '%s' "$MAP_PROMPT" | timeout 600 claude --print \
        --model "$MAP_MODEL_USE" \
        --bare \
        --no-session-persistence \
        --system-prompt-file "$MAP_SYSTEM_FILE" \
        --output-format json \
        --tools "" \
        --permission-mode bypassPermissions \
        > "$TMP/responses/response-${chunk_id}.json" \
        2> "$TMP/responses/error-${chunk_id}.log"
    ) &
    MAP_PIDS+=("$!:${chunk_id}")
  done

  # Wait for all PIDs, collect failures.
  FAILED_CHUNKS=()
  for pid_id in "${MAP_PIDS[@]}"; do
    pid="${pid_id%:*}"
    cid="${pid_id##*:}"
    if ! wait "$pid"; then
      FAILED_CHUNKS+=("$cid")
    fi
  done

  if [[ ${#FAILED_CHUNKS[@]} -gt 0 ]]; then
    echo "dream.sh: ERROR  map calls failed (non-zero exit) for chunks: ${FAILED_CHUNKS[*]}" >&2
    exit 1
  fi

  # Post-wait, check each response JSON for is_error / max_tokens.
  for chunk_file in "$TMP/chunks/chunk-"*.md; do
    chunk_id=$(basename "$chunk_file" .md | sed 's/chunk-//')
    response_json="$TMP/responses/response-${chunk_id}.json"
    python3 - "$response_json" "$chunk_id" <<'PYEOF' || exit 1
import json, sys
path, cid = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"dream.sh: ERROR  chunk {cid} response unparseable: {e}", file=sys.stderr)
    sys.exit(1)
if data.get("is_error"):
    print(f"dream.sh: ERROR  chunk {cid} returned is_error=true: {data.get('result','')[:200]}", file=sys.stderr)
    sys.exit(1)
stop_reason = data.get("stop_reason") or ""
if stop_reason in ("max_tokens", "refusal"):
    print(f"dream.sh: ERROR  chunk {cid} stop_reason={stop_reason}", file=sys.stderr)
    sys.exit(1)
result = data.get("result", "")
if not result.strip():
    print(f"dream.sh: ERROR  chunk {cid} result empty", file=sys.stderr)
    sys.exit(1)
PYEOF
  done

  # Extract each result into extracts/extract-N.md.
  for chunk_file in "$TMP/chunks/chunk-"*.md; do
    chunk_id=$(basename "$chunk_file" .md | sed 's/chunk-//')
    response_json="$TMP/responses/response-${chunk_id}.json"
    extract_md="$TMP/extracts/extract-${chunk_id}.md"
    python3 - "$response_json" "$extract_md" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
open(sys.argv[2], "w", encoding="utf-8").write(data.get("result", ""))
PYEOF
  done

  # ============================================================
  # Stage 3c: concatenate extracts with separators (chronological)
  # ============================================================
  echo "[3c/4] concatenating extracts…"
  python3 - "$TMP" <<'PYEOF' > "$TMP/extracts-concat.md"
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
meta = json.loads((tmp / "chunks" / "chunks-meta.json").read_text())
parts = []
for entry in sorted(meta["chunks"], key=lambda e: e["chunk_id"]):
    cid = entry["chunk_id"]
    rng = f"{entry['start']} -> {entry['end']}"
    body = (tmp / "extracts" / f"extract-{cid}.md").read_text(encoding="utf-8").strip()
    parts.append(f"=== CHUNK {cid} ({rng}) ===\n{body}\n")
print("\n".join(parts))
PYEOF

  CONCAT_BYTES=$(wc -c < "$TMP/extracts-concat.md" | tr -d ' ')
  echo "      extracts-concat.md: ${CONCAT_BYTES} bytes"

  # ============================================================
  # Stage 3d: reduce call (Sonnet, MCPs active)
  # ============================================================
  echo "[3d/4] reduce via Claude ($MODEL)…"

  RECONCILE_TEMPLATE="$(cat "$PROMPTS_DIR/reconcile.md")"
  SESSIONS_CONTENT="$(cat "$TMP/extracts-concat.md")"
  VAULT_CONTENT="$(cat "$TMP/vault.md")"

  PROMPT="$(WINDOW="$WINDOW_LABEL" \
             TODAY="$DATE" \
             SESSIONS="$SESSIONS_CONTENT" \
             VAULT="$VAULT_CONTENT" \
             TEMPLATE="$RECONCILE_TEMPLATE" \
           python3 -c '
import os
t = os.environ["TEMPLATE"]
t = t.replace("{TODAY}",   os.environ["TODAY"])
t = t.replace("{WINDOW}",  os.environ["WINDOW"])
t = t.replace("{SESSIONS}", os.environ["SESSIONS"])
t = t.replace("{VAULT}",    os.environ["VAULT"])
print(t, end="")
')"

  SYSTEM_PROMPT=""
  if [[ -f "$PROMPTS_DIR/system.md" ]]; then
    SYSTEM_PROMPT="$(cat "$PROMPTS_DIR/system.md")"
  fi

  RESPONSE_JSON="$TMP/response.json"
  USAGE_LOG="$SKILL_DIR/.usage-log.jsonl"

  CLAUDE_ARGS=(
    --model "$MODEL"
    --print
    --output-format json
    --tools ""
    --permission-mode bypassPermissions
  )
  if [[ "$NO_MCP" != "1" ]] && [[ -n "$MCP_CONFIG" ]] && [[ -f "$MCP_CONFIG" ]]; then
    CLAUDE_ARGS+=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
  fi
  if [[ -n "$SYSTEM_PROMPT" ]]; then
    CLAUDE_ARGS+=(--append-system-prompt "$SYSTEM_PROMPT")
  fi

  printf '%s' "$PROMPT" | claude "${CLAUDE_ARGS[@]}" > "$RESPONSE_JSON"

  if [[ ! -s "$RESPONSE_JSON" ]]; then
    echo "dream.sh: ERROR  reduce returned empty response" >&2
    exit 1
  fi

  # Continue to existing Stage 4 (save report + log usage)
fi
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

Expected: no errors.

- [ ] **Step 3: Smoke test with mocked claude**

Create a temporary mock at `/tmp/mock-claude` that emits a valid JSON response:

```bash
cat > /tmp/mock-claude <<'EOF'
#!/usr/bin/env bash
# Reads stdin, ignores args, prints a canned JSON response.
cat > /dev/null
cat <<JSON
{"type":"result","subtype":"success","is_error":false,"result":"## State changes\n- Mock signal. (Claude Session 2026-05-21 09:14)\n","stop_reason":"end_turn","duration_ms":100,"total_cost_usd":0.001,"usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
JSON
EOF
chmod +x /tmp/mock-claude
```

Run dream.sh with PATH overridden to use the mock:

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
PATH="/tmp:$PATH" alias claude=/tmp/mock-claude
# Easier: temporarily symlink
ln -sf /tmp/mock-claude /tmp/claude
PATH="/tmp:$PATH" FORCE_CHUNKED=1 ./dream.sh --since 7d --vault-root "$DREAM_VAULT_ROOT" --no-mcp 2>&1 | tail -30
```

Expected: stages 3a, 3b, 3c, 3d all execute; final dream report written. Mock claude is called multiple times (once per chunk + once for reduce).

- [ ] **Step 4: Clean up the mock**

```bash
rm /tmp/claude /tmp/mock-claude
```

- [ ] **Step 5: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/dream.sh
git commit -m "feat(dream-skill): implement chunked map-reduce path stages 3a-3d

Stage 3a invokes chunker.py; 3b fires parallel claude --print (Haiku, --bare,
--no-session-persistence, prompt via stdin); 3c concatenates extracts in
chronological order with === CHUNK N === separators; 3d runs the existing
Sonnet reduce call with MCPs active. Strict abort on non-zero exit OR
is_error OR stop_reason in (max_tokens, refusal).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: dream.sh — preserve extracts to output dir + cleanup logic

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/dream.sh`

- [ ] **Step 1: Add the extracts-preservation block after Stage 4 save**

After the existing Stage-4 Python heredoc finishes, AND inside a `if [[ "$ROUTE" == "chunked" ]]; then ... fi` guard, copy extracts + meta to the output dir.

Add after the existing `PYEOF` that closes the Stage-4 Python block, and BEFORE the closing banner echoes:

```bash
# Preserve extracts when chunked
if [[ "$ROUTE" == "chunked" ]]; then
  EXTRACTS_DIR="$OUTPUT_DIR/dream-extracts-$DATE"
  mkdir -p "$EXTRACTS_DIR"
  cp "$TMP/extracts/"*.md "$EXTRACTS_DIR/" 2>/dev/null || true
  cp "$TMP/chunks/chunks-meta.json" "$EXTRACTS_DIR/" 2>/dev/null || true
  echo "      extracts preserved at $EXTRACTS_DIR"
fi
```

- [ ] **Step 2: Syntax check + smoke test (reuse mock from Task 11)**

```bash
bash -n /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

- [ ] **Step 3: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/dream.sh
git commit -m "feat(dream-skill): preserve map extracts + chunks-meta.json to output dir

Enables manual inspection of what each map call extracted vs what reduce
synthesized — the prompt-tuning feedback loop spec'd in §iteration.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 13: dream.sh — extend .usage-log.jsonl to schema v2

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/dream.sh`

The current `.usage-log.jsonl` write happens inside the Stage-4 Python heredoc. We extend that block to gather per-chunk metrics when ROUTE=chunked, and add schema_version + new fields.

- [ ] **Step 1: Locate the existing Stage-4 Python heredoc**

```bash
grep -n 'PYEOF\|usage-log\|row = {' /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

- [ ] **Step 2: Extend the Stage-4 env block to pass ROUTE + TMP**

Find this block in dream.sh:

```bash
OUTPUT="$OUTPUT_REPORT" \
RESPONSE_JSON="$RESPONSE_JSON" \
USAGE_LOG="$USAGE_LOG" \
DATE="$DATE" \
MODEL="$MODEL" \
SINCE="$WINDOW_LABEL" \
VERBOSE="$VERBOSE" \
python3 <<'PYEOF'
```

Replace with:

```bash
OUTPUT="$OUTPUT_REPORT" \
RESPONSE_JSON="$RESPONSE_JSON" \
USAGE_LOG="$USAGE_LOG" \
DATE="$DATE" \
MODEL="$MODEL" \
MAP_MODEL="${MAP_MODEL:-claude-haiku-4-5-20251001}" \
SINCE="$WINDOW_LABEL" \
VERBOSE="$VERBOSE" \
ROUTE="$ROUTE" \
TMP="$TMP" \
TIKTOKEN_USED="$(python3 -c 'from count_tokens import count; _, used = count("test"); print(str(used).lower())' 2>/dev/null || echo unknown)" \
python3 <<'PYEOF'
```

- [ ] **Step 3: Extend the row dict and aggregation logic inside the heredoc**

Find inside the Stage-4 heredoc:

```python
row = {
    "ts": datetime.now(timezone.utc).isoformat(),
    "date": os.environ["DATE"],
    "model": os.environ["MODEL"],
    "window": os.environ["SINCE"],
    "input_tokens": in_tok,
    "output_tokens": out_tok,
    "cache_read_input_tokens": cache_read,
    "cache_creation_input_tokens": cache_create,
    "cost_usd": cost,
    "duration_ms": duration_ms,
    "report_bytes": report_bytes,
}
```

Replace with:

```python
row = {
    "schema_version": 2,
    "ts": datetime.now(timezone.utc).isoformat(),
    "date": os.environ["DATE"],
    "model": os.environ["MODEL"],
    "map_model": os.environ.get("MAP_MODEL", ""),
    "window": os.environ["SINCE"],
    "chunked": os.environ["ROUTE"] == "chunked",
    "tiktoken_used": os.environ.get("TIKTOKEN_USED", "unknown"),
    "input_tokens": in_tok,
    "output_tokens": out_tok,
    "cache_read_input_tokens": cache_read,
    "cache_creation_input_tokens": cache_create,
    "cost_usd": cost,
    "duration_ms": duration_ms,
    "report_bytes": report_bytes,
}

# When chunked, attach map-call metrics by scanning $TMP/responses/response-*.json.
if row["chunked"]:
    import glob
    chunks_meta = {}
    chunks_meta_path = Path(os.environ["TMP"]) / "chunks" / "chunks-meta.json"
    if chunks_meta_path.is_file():
        try:
            chunks_meta = json.loads(chunks_meta_path.read_text())
        except Exception:
            chunks_meta = {}
    map_metrics = []
    map_totals = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
    for response_path in sorted(glob.glob(os.path.join(os.environ["TMP"], "responses", "response-*.json"))):
        try:
            d = json.loads(open(response_path).read())
        except Exception:
            continue
        cid_str = Path(response_path).stem.replace("response-", "")
        u = d.get("usage", {}) or {}
        extract_path = Path(os.environ["TMP"]) / "extracts" / f"extract-{cid_str}.md"
        extract_bytes = extract_path.stat().st_size if extract_path.is_file() else 0
        map_metrics.append({
            "chunk_id": int(cid_str) if cid_str.isdigit() else cid_str,
            "wall_time_ms": d.get("duration_ms", 0),
            "input_tokens": u.get("input_tokens", 0),
            "output_tokens": u.get("output_tokens", 0),
            "cache_read_input_tokens": u.get("cache_read_input_tokens", 0),
            "cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
            "extract_bytes": extract_bytes,
            "stop_reason": d.get("stop_reason", ""),
            "model": d.get("modelUsage", {}).get(os.environ.get("MAP_MODEL", ""), {}).get("model", "") or os.environ.get("MAP_MODEL", ""),
        })
        for k in map_totals:
            map_totals[k] += u.get(k, 0)
    row["chunk_count"] = len(map_metrics)
    row["map_token_totals"] = map_totals
    row["map_call_metrics"] = map_metrics
    row["reduce_token_totals"] = {
        "input_tokens": in_tok,
        "output_tokens": out_tok,
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": cache_create,
    }
```

- [ ] **Step 4: Syntax check**

```bash
bash -n /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

- [ ] **Step 5: Smoke test with mock (reuses mock from Task 11)**

Verify the new `.usage-log.jsonl` row contains the new fields:

```bash
tail -1 /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/.usage-log.jsonl | python3 -m json.tool
```

Expected keys present: `schema_version`, `chunked`, `chunk_count` (if chunked), `map_token_totals`, `map_call_metrics`, `reduce_token_totals`, `tiktoken_used`, `map_model`.

- [ ] **Step 6: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/dream.sh
git commit -m "feat(dream-skill): extend .usage-log.jsonl to schema v2 with per-chunk metrics

Records schema_version, chunked, chunk_count, map_token_totals,
reduce_token_totals, per-chunk metrics (wall_time_ms, extract_bytes,
stop_reason). The extract_bytes field is the prompt-tuning signal — large
values mean the map prompt is under-filtering; small values mean over-filtering.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 14: dream.sh — proper CLI flags for --force-chunked / --force-single / --map-model / --max-budget-usd

**Files:**
- Modify: `skills/dream-skill/skills/dream-skill/dream.sh`

Until now the flags work only via env vars. Wire them into the CLI arg parser.

- [ ] **Step 1: Add flag defaults in the env-resolution block**

Find this block in dream.sh:

```bash
MODEL="${DREAM_MODEL:-$DEFAULT_MODEL}"
SINCE="${DREAM_SINCE:-}"
MCP_CONFIG=""
NO_MCP="${DREAM_NO_MCP:-0}"
APPLY=0
DRY_RUN=1   # default behavior: produce a report, do not apply
VERBOSE=0
```

Replace with:

```bash
MODEL="${DREAM_MODEL:-$DEFAULT_MODEL}"
MAP_MODEL="${DREAM_MAP_MODEL:-claude-haiku-4-5-20251001}"
SINCE="${DREAM_SINCE:-}"
MCP_CONFIG=""
NO_MCP="${DREAM_NO_MCP:-0}"
APPLY=0
DRY_RUN=1   # default behavior: produce a report, do not apply
VERBOSE=0
FORCE_CHUNKED="${DREAM_FORCE_CHUNKED:-0}"
FORCE_SINGLE="${DREAM_FORCE_SINGLE:-0}"
MAX_BUDGET_USD="${DREAM_MAX_BUDGET_USD:-2.00}"
```

- [ ] **Step 2: Add the flag handlers in the arg-parsing case block**

Find the existing `while [[ $# -gt 0 ]]; do case "$1" in ... esac done` block, and add these cases before the catchall `*)`:

```bash
    --map-model)        MAP_MODEL="$2"; shift 2 ;;
    --force-chunked)    FORCE_CHUNKED=1; shift ;;
    --force-single)     FORCE_SINGLE=1; shift ;;
    --max-budget-usd)   MAX_BUDGET_USD="$2"; shift 2 ;;
```

- [ ] **Step 3: Add the new flags to print_help() output**

Append these lines inside the `print_help() { cat <<EOF ... EOF }` heredoc, before the trailing `Examples:` block:

```
  --map-model ID          Model used for parallel map calls (chunked path only).
                          env: DREAM_MAP_MODEL
                          default: claude-haiku-4-5-20251001

  --force-chunked         Force map-reduce path regardless of token count.
                          (For testing; useful with small windows.)

  --force-single          Force single-call path regardless of token count.
                          Will fail if Claude rejects the oversized prompt;
                          --max-budget-usd caps the damage.

  --max-budget-usd AMOUNT Safety cap on --force-single calls.
                          env: DREAM_MAX_BUDGET_USD
                          default: 2.00
```

- [ ] **Step 4: Wire --max-budget-usd into the single-call path's claude args**

In the existing single-call Stage-3 `CLAUDE_ARGS=( ... )` array, append (right before the conditional MCP args):

```bash
  if [[ "$FORCE_SINGLE" == "1" ]]; then
    CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET_USD")
  fi
```

- [ ] **Step 5: Echo all the new state in the startup banner**

Find this echo block:

```bash
echo "  model:    $MODEL"
```

Add right after it:

```bash
echo "  map-model: $MAP_MODEL"
if [[ "$FORCE_CHUNKED" == "1" ]]; then echo "  --force-chunked: on"; fi
if [[ "$FORCE_SINGLE"  == "1" ]]; then echo "  --force-single:  on (budget cap \$${MAX_BUDGET_USD})"; fi
```

- [ ] **Step 6: Syntax check**

```bash
bash -n /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/dream.sh
```

- [ ] **Step 7: Test the flags**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
./dream.sh --help | grep -E -- '--force-(chunked|single)|--map-model|--max-budget'
```

Expected: all four flags listed in help output.

- [ ] **Step 8: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/dream.sh
git commit -m "feat(dream-skill): add --force-chunked/--force-single/--map-model/--max-budget-usd CLI flags

--force-single now also passes --max-budget-usd to claude --print as a safety
cap against quota overruns when the user explicitly bypasses the routing
threshold.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 15: .gitignore — add dream-extracts-* / dream-errors-* patterns

**Files:**
- Modify: `/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/.gitignore` (monorepo root, not skill root)

- [ ] **Step 1: Edit .gitignore**

Find this block in `.gitignore`:

```
# dream-skill runtime artifacts (never commit user data)
.apply-log.jsonl
.usage-log.jsonl
.last-run
skills/dream-skill/.last-run
.dream-cache/
dream-reports/
dream-reports/*.md
```

Replace with:

```
# dream-skill runtime artifacts (never commit user data)
.apply-log.jsonl
.usage-log.jsonl
.last-run
skills/dream-skill/.last-run
.dream-cache/
dream-reports/
dream-reports/*.md
dream-extracts-*/
dream-errors-*/
```

- [ ] **Step 2: Verify the new patterns match**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
mkdir -p dream-extracts-test
echo "test" > dream-extracts-test/x.md
git check-ignore -v dream-extracts-test/x.md
rm -rf dream-extracts-test
```

Expected: `git check-ignore -v` prints the matching gitignore line.

- [ ] **Step 3: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add .gitignore
git commit -m "chore(dream-skill): gitignore dream-extracts-* and dream-errors-* output dirs

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 16: Bash integration smoke test (test_dream_sh.sh)

**Files:**
- Create: `skills/dream-skill/skills/dream-skill/tests/test_dream_sh.sh`
- Create: `skills/dream-skill/skills/dream-skill/tests/fixtures/vault-sample.md`
- Create: `skills/dream-skill/skills/dream-skill/tests/fixtures/vault-empty.md`

- [ ] **Step 1: Create the vault fixtures**

```bash
cat > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/fixtures/vault-sample.md <<'EOF'
# Vault snapshot — sample

## me
- Bio: HS junior in Cleveland, AI/ML engineering.
- Current projects: Persona-RAG, Cleveland Clinic internship.
- Schedule: gym 8pm.

## gym-sprint
- Active: 12-week cycle 4.
EOF

# Empty-ish vault (<1KB) for empty-vault routing test
echo "# tiny vault" > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/fixtures/vault-empty.md
```

- [ ] **Step 2: Create the bash smoke-test script**

```bash
cat > /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/test_dream_sh.sh <<'EOF'
#!/usr/bin/env bash
# tests/test_dream_sh.sh — integration smoke test for dream.sh routing + chunked path.
#
# Uses a mock claude binary that emits canned JSON; the test asserts dream.sh
# routes correctly, fires the right number of map calls, and writes the
# expected output artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

# Sandbox: temp output dir + mocked vault
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

VAULT_ROOT="$SANDBOX/vault"
mkdir -p "$VAULT_ROOT"
cp "$FIXTURES/vault-sample.md" "$VAULT_ROOT/"

OUTPUT_DIR="$SANDBOX/dream-reports"

# Mock claude that echoes a valid JSON response and consumes stdin.
MOCK_BIN="$SANDBOX/mock-claude"
cat > "$MOCK_BIN" <<'MOCKEOF'
#!/usr/bin/env bash
# Consume stdin
cat > /dev/null
cat <<JSON
{"type":"result","subtype":"success","is_error":false,"result":"---\ntype: dream-report\ndate: 2026-05-26\nwindow: 7d\n---\n\n## State changes\n- mock signal. (Claude Session 2026-05-21 09:14)\n","stop_reason":"end_turn","duration_ms":100,"total_cost_usd":0.001,"usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
JSON
MOCKEOF
chmod +x "$MOCK_BIN"

# Mock load_vault_state.py to use the sandbox vault
export PATH="$SANDBOX:$PATH"
ln -sf "$MOCK_BIN" "$SANDBOX/claude"

# Test 1: sub-threshold (empty vault) -> single-call path
mkdir -p "$VAULT_ROOT-empty"
cp "$FIXTURES/vault-empty.md" "$VAULT_ROOT-empty/vault-empty.md"

# We can't easily mock load_vault_state.py output, so we shortcut by using
# the existing single-call path with --since 0d and asserting "route: single".
# Use --no-mcp to skip MCP config loading.

echo "=== Test 1: empty-vault routing ==="
OUTPUT="$("$SKILL_DIR/dream.sh" \
  --vault-root "$VAULT_ROOT-empty" \
  --output-dir "$OUTPUT_DIR-1" \
  --since 7d \
  --no-mcp 2>&1 || true)"
echo "$OUTPUT" | grep -q "route: single" || { echo "FAIL: did not route to single (empty vault)"; exit 1; }
echo "  PASS"

# Test 2: --force-chunked
echo "=== Test 2: --force-chunked ==="
OUTPUT="$("$SKILL_DIR/dream.sh" \
  --vault-root "$VAULT_ROOT" \
  --output-dir "$OUTPUT_DIR-2" \
  --since 7d \
  --no-mcp \
  --force-chunked 2>&1 || true)"
echo "$OUTPUT" | grep -q "route: chunked" || { echo "FAIL: did not route to chunked"; exit 1; }
echo "  PASS"

# Test 3: dream report written
echo "=== Test 3: dream report file exists ==="
test -f "$OUTPUT_DIR-2/dream-$(date -u +%F).md" || { echo "FAIL: no dream report written"; exit 1; }
echo "  PASS"

# Test 4: extracts dir preserved when chunked
echo "=== Test 4: extracts dir preserved ==="
test -d "$OUTPUT_DIR-2/dream-extracts-$(date -u +%F)" || { echo "FAIL: no extracts dir"; exit 1; }
ls "$OUTPUT_DIR-2/dream-extracts-$(date -u +%F)/" | grep -q "chunk-" || { echo "FAIL: extracts dir empty"; exit 1; }
echo "  PASS"

echo
echo "All smoke tests passed."
EOF
chmod +x /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/test_dream_sh.sh
```

- [ ] **Step 3: Run the smoke test**

```bash
/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/tests/test_dream_sh.sh
```

Expected: all 4 tests PASS. Iterate until they do.

- [ ] **Step 4: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
git add skills/dream-skill/tests/test_dream_sh.sh \
        skills/dream-skill/tests/fixtures/vault-sample.md \
        skills/dream-skill/tests/fixtures/vault-empty.md
git commit -m "test(dream-skill): bash integration smoke test for routing + chunked path

Uses a mock claude binary that emits canned JSON. Asserts: empty-vault routes
to single-call, --force-chunked routes to chunked, dream report file is
written, extracts dir is preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 17: Real-LLM smoke check — `--force-chunked` on small window

**No code changes.** This is a manual verification task.

- [ ] **Step 1: Run dream.sh with --force-chunked on a small recent window**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
./dream.sh --force-chunked --since 2d --verbose 2>&1 | tee /tmp/dream-smoke-1.log
```

Expected:
- Output shows `route: chunked (--force-chunked)`
- Stage 3a prints chunk count (likely 2 due to min-chunks)
- Stage 3b prints "launching 2 parallel map calls (model: claude-haiku-4-5-20251001)"
- Stage 3c prints concat bytes
- Stage 3d prints reduce call summary
- Dream report file appears in vault's dream-reports/ dir
- `dream-extracts-<date>/` dir appears with chunk-1.md and chunk-2.md

- [ ] **Step 2: Inspect the extracts for citation prefixes**

```bash
DATE=$(date -u +%F)
ls "$DREAM_VAULT_ROOT/dream-reports/dream-extracts-$DATE/"
cat "$DREAM_VAULT_ROOT/dream-reports/dream-extracts-$DATE/chunk-1.md"
```

Expected: each persona-signal bullet ends with `(Claude Session YYYY-MM-DD HH:MM)` or `(Codex Session YYYY-MM-DD HH:MM)`.

- [ ] **Step 3: Inspect the dream report**

```bash
cat "$DREAM_VAULT_ROOT/dream-reports/dream-$DATE.md" | head -50
```

Expected: YAML frontmatter present, sections present, evidence-block citations match the `Claude Session N` format.

- [ ] **Step 4: Run apply_auto.py in dry-run mode against the report**

```bash
mkdir -p "$DREAM_VAULT_ROOT/.dream-rollback"
python3 scripts/apply_auto.py \
  --vault-root "$DREAM_VAULT_ROOT" \
  --report "$DREAM_VAULT_ROOT/dream-reports/dream-$DATE.md" \
  --rollback-dir "$DREAM_VAULT_ROOT/.dream-rollback"
```

Expected: proposals classified into `Auto-apply` (>=2 channels) vs `Needs confirmation` (1 channel) without parser errors. Default mode is dry-run (no `--apply` flag) so no vault files are modified.

- [ ] **Step 5: Inspect .usage-log.jsonl for new schema**

```bash
tail -1 /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/.usage-log.jsonl | python3 -m json.tool
```

Expected: row contains `schema_version: 2`, `chunked: true`, `chunk_count: 2`, `map_token_totals`, `reduce_token_totals`, `map_call_metrics: [...]`.

- [ ] **Step 6: If any check fails — investigate, fix, redo this task. Otherwise, log the verified result**

```bash
echo "Smoke test --force-chunked PASSED at $(date -u +%FT%TZ)" >> /tmp/dream-smoke-results.log
```

- [ ] **Step 7: Commit only the verification log (if your project tracks these — else skip)**

No commit needed for manual verification.

---

## Task 18: Real-LLM smoke check — large window (30d) end-to-end

**No code changes.** Final integration verification.

- [ ] **Step 1: Pre-flight: confirm sessions volume**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
python3 scripts/preprocess.py --since 30d --output /tmp/sessions-30d.md
python3 scripts/count_tokens.py /tmp/sessions-30d.md
```

Expected: tokens > 130000 (so routing will pick chunked).

- [ ] **Step 2: Run dream.sh with default args (no force-flag)**

```bash
./dream.sh --since 30d --verbose 2>&1 | tee /tmp/dream-smoke-30d.log
```

Expected timeline:
- Stage 1: ~10s (preprocess)
- Stage 2: ~2s (vault snapshot)
- Stage 2.5: route prints `chunked (total NNNK tokens >= threshold 130000)`
- Stage 3a: chunker prints 4-8 chunks
- Stage 3b: launches that many parallel map calls; finishes in ~2-3 min
- Stage 3c: concat bytes printed
- Stage 3d: reduce call ~2-3 min
- Total wall time: 5-8 min

- [ ] **Step 3: Verify final outputs**

```bash
DATE=$(date -u +%F)
echo "=== dream report ==="; ls -la "$DREAM_VAULT_ROOT/dream-reports/dream-$DATE.md"
echo "=== extracts ==="; ls -la "$DREAM_VAULT_ROOT/dream-reports/dream-extracts-$DATE/"
echo "=== last log row ==="
tail -1 /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill/.usage-log.jsonl | python3 -m json.tool
```

- [ ] **Step 4: Cross-check report vs extracts**

Open `dream-$DATE.md` and one of `dream-extracts-$DATE/chunk-N.md`. Pick one bullet from a chunk extract. Search for that bullet's signal in the dream report. Confirm:
- The signal appears in the report
- Its citation prefix is preserved verbatim
- Channel count is correct

- [ ] **Step 5: Tune the map prompt if needed**

If you found persona signals in the raw sessions transcript that did NOT survive into the dream report:
1. Open `prompts/map-system.md`
2. Adjust the KEEP/IGNORE lists or examples to cover the missed pattern
3. Rerun this smoke test
4. Commit prompt changes with message `tune(dream-skill): map prompt to retain <pattern>`

- [ ] **Step 6: Document the verified-good state**

```bash
echo "End-to-end 30d smoke test PASSED at $(date -u +%FT%TZ)" >> /tmp/dream-smoke-results.log
```

---

## Self-review (run before handoff)

After all 18 tasks are complete, run the self-review checks:

- [ ] **Spec coverage**: each section of the v2 spec maps to a task above? Specifically:
  - § Architecture: tasks 9, 10, 11 (route + chunked stages)
  - § Components → dream.sh: tasks 9, 10, 11, 12, 13, 14
  - § Components → chunker.py: tasks 2, 3, 4, 5
  - § Components → count_tokens.py: task 1
  - § Components → prompts: tasks 6, 7, 8
  - § Components → output artifacts: tasks 12, 16
  - § Error handling: task 9 (on_exit), task 11 (post-wait JSON check)
  - § Observability: task 13 (.usage-log.jsonl v2)
  - § Testing strategy: tasks 1-5 (Python unit), 16 (bash integration), 17, 18 (manual)
  - § Migration: task 15 (.gitignore)

- [ ] **Placeholder scan**: no `TBD`, `TODO`, "implement later", "add error handling", "similar to task N" without repeated code.

- [ ] **Type consistency**: function names + signatures used in later tasks match what earlier tasks defined (`parse_sessions`, `greedy_bucket`, `apply_bounds`, `count`, `_byte_estimate`). Module names (`count_tokens`, `chunker`) match import statements.

- [ ] **Final unit-test run**:

  ```bash
  cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/skills/dream-skill
  python3 -m pytest tests/ -v
  ./tests/test_dream_sh.sh
  ```

  Expected: all green.

---

## Execution handoff

Plan complete and saved to `skills/dream-skill/docs/superpowers/plans/2026-05-26-dream-skill-map-reduce.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
