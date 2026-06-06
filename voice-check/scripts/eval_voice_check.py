#!/usr/bin/env python3
"""Thin wrapper for `voice-check eval` (runs without installing the CLI)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from voice_check.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main(["eval", *sys.argv[1:]]))
