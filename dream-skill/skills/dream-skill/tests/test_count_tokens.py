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


def test_count_empty_string_reports_correct_tiktoken_flag():
    """Empty input should still report whether tiktoken is available, not always False."""
    try:
        import tiktoken  # noqa: F401
        tiktoken_available = True
    except ImportError:
        tiktoken_available = False

    _, used = count_tokens.count("")
    assert used is tiktoken_available


def test_cli_mode_missing_file_exits_with_clean_error(tmp_path: Path):
    """Non-existent path should produce a clean stderr message + exit 1, not a traceback."""
    script_path = Path(__file__).resolve().parent.parent / "scripts" / "count_tokens.py"
    missing = tmp_path / "does-not-exist.txt"
    result = subprocess.run(
        ["python3", str(script_path), str(missing)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "cannot read" in result.stderr.lower() or "no such file" in result.stderr.lower()
    # Must NOT contain a Python traceback
    assert "Traceback" not in result.stderr
