from __future__ import annotations

from datetime import date
import importlib.util
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "current_page_lint.py"
spec = importlib.util.spec_from_file_location("current_page_lint", SCRIPT_PATH)
assert spec and spec.loader
current_page_lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(current_page_lint)


def test_lint_flags_stale_as_of_expired_week_and_past_current_events() -> None:
    text = """---
updated: 2026-07-18
---
# Now

## As of 2026-07-03

## This week (W6: 6/29 – 7/5)
- Fri 7/3 (today): send the follow-up

## Hard dates ahead
- 2026-07-15: first contract target
- 2026-08-25: school resumes
"""

    findings = current_page_lint.lint_text(
        text,
        Path("Now.md"),
        today=date(2026, 7, 28),
    )

    assert {finding["signal"] for finding in findings} == {
        "stale_as_of",
        "expired_weekly_section",
        "past_current_event",
    }
    assert any(finding["line"] == 9 for finding in findings)
    assert any("2026-07-15" in finding["message"] for finding in findings)


def test_lint_ignores_resolved_historical_dates_and_fresh_sections() -> None:
    text = """# Now

## As of 2026-07-28

## This week (W9: 7/27 – 8/2)
- 2026-07-27: active planning
- 2026-07-03: old target, resolved
"""

    findings = current_page_lint.lint_text(
        text,
        Path("Now.md"),
        today=date(2026, 7, 28),
    )

    assert findings == []


def test_cli_strict_returns_nonzero_for_findings(tmp_path, capsys) -> None:
    page = tmp_path / "Now.md"
    page.write_text("## As of 2026-07-01\n", encoding="utf-8")

    exit_code = current_page_lint.main(
        [str(page), "--today", "2026-07-28", "--strict"]
    )

    assert exit_code == 1
    assert "stale_as_of" in capsys.readouterr().out
