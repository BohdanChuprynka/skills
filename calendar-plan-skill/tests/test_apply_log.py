"""Tests for apply_log.py run-log summarization."""

from __future__ import annotations

import importlib.util
from pathlib import Path

APPLY = Path(__file__).resolve().parent.parent / "skills" / "calendar-plan" / "scripts" / "apply_log.py"
spec = importlib.util.spec_from_file_location("apply_log", APPLY)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(mod)


def test_action_lines_capture_event_context_not_placeholder():
    # Regression: lines used to render "- created  ?  07:00", dropping the event.
    log = "Created 'Morning gym' at 07:00 on the Health calendar.\n"
    lines = mod.build_action_lines(log)
    joined = "\n".join(lines)
    assert "07:00" in joined
    assert "Morning gym" in joined
    assert "?" not in joined


def test_action_lines_report_no_verbs():
    lines = mod.build_action_lines("nothing actionable in this text")
    assert any("no create/change" in line for line in lines)


def test_action_lines_pause_only():
    lines = mod.build_action_lines("Planner paused; not writing anything.")
    assert any("pause" in line.lower() for line in lines)
