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
    """Cheap fallback: ~4.0 chars per token on prose (cl100k_base calibrated)."""
    return int(len(text) / 4.0)


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
