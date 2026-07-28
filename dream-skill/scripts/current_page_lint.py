#!/usr/bin/env python3
"""Report stale dates and expired current sections without editing pages."""

from __future__ import annotations

import argparse
import json
import re
from datetime import date, datetime
from pathlib import Path
from typing import Iterable


AS_OF_RE = re.compile(r"^\s*(?:>\s*)?(?:#+\s*)?As of\s+(\d{4}-\d{2}-\d{2})\b", re.IGNORECASE)
WEEK_RE = re.compile(
    r"^\s*#{1,6}\s+This week\b.*?(\d{1,2})/(\d{1,2})\s*[\-–]\s*(\d{1,2})/(\d{1,2})",
    re.IGNORECASE,
)
DATE_RE = re.compile(r"(?<!\d)(?:(\d{4})-(\d{1,2})-(\d{1,2})|(\d{1,2})/(\d{1,2}))(?!\d)")
CURRENT_SECTION_RE = re.compile(r"^\s*#{1,6}\s+(This week|Hard dates ahead)\b", re.IGNORECASE)
SAFE_HISTORY_RE = re.compile(
    r"\b(resolved|completed|superseded|cancelled|canceled|archived|done|shipped|retired)\b",
    re.IGNORECASE,
)
PAST_EVENT_GRACE_DAYS = 1


def _date_from_match(match: re.Match[str], today: date) -> date | None:
    try:
        if match.group(1):
            return date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
        return date(today.year, int(match.group(4)), int(match.group(5)))
    except ValueError:
        return None


def _finding(path: Path, line: int, signal: str, message: str, found_date: date | None = None) -> dict[str, object]:
    result: dict[str, object] = {
        "file": str(path),
        "line": line,
        "signal": signal,
        "severity": "medium",
        "message": message,
    }
    if found_date is not None:
        result["date"] = found_date.isoformat()
    return result


def lint_text(
    text: str,
    path: Path,
    *,
    today: date | None = None,
    stale_after_days: int = 7,
) -> list[dict[str, object]]:
    """Return conservative findings for a page that claims to be current."""
    today = today or date.today()
    findings: list[dict[str, object]] = []
    current_section: str | None = None

    for line_number, line in enumerate(text.splitlines(), start=1):
        as_of = AS_OF_RE.match(line)
        if as_of:
            try:
                as_of_date = date.fromisoformat(as_of.group(1))
            except ValueError:
                as_of_date = None
            if as_of_date and (today - as_of_date).days > stale_after_days:
                findings.append(
                    _finding(
                        path,
                        line_number,
                        "stale_as_of",
                        f"As-of date {as_of_date.isoformat()} is {(today - as_of_date).days} days old.",
                        as_of_date,
                    )
                )

        week = WEEK_RE.match(line)
        if week:
            start = date(today.year, int(week.group(1)), int(week.group(2)))
            end = date(today.year, int(week.group(3)), int(week.group(4)))
            if end < start:
                end = date(today.year + 1, int(week.group(3)), int(week.group(4)))
            if end < today:
                findings.append(
                    _finding(
                        path,
                        line_number,
                        "expired_weekly_section",
                        f"This-week section ended {end.isoformat()} and is still presented as current.",
                        end,
                    )
                )

        section = CURRENT_SECTION_RE.match(line)
        if section:
            current_section = section.group(1).lower()
            continue
        if line.lstrip().startswith("#"):
            current_section = None

        if current_section and DATE_RE.search(line) and not SAFE_HISTORY_RE.search(line):
            for match in DATE_RE.finditer(line):
                found_date = _date_from_match(match, today)
                if found_date and (today - found_date).days > PAST_EVENT_GRACE_DAYS:
                    findings.append(
                        _finding(
                            path,
                            line_number,
                            "past_current_event",
                            f"{current_section.title()} contains past date {found_date.isoformat()} without a resolved or historical marker.",
                            found_date,
                        )
                    )
                    break

    return findings


def lint_path(path: Path, *, today: date | None = None, stale_after_days: int = 7) -> list[dict[str, object]]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [_finding(path, 0, "unreadable_page", f"Could not read current page: {exc}")]
    return lint_text(text, path, today=today, stale_after_days=stale_after_days)


def lint_paths(paths: Iterable[Path], *, today: date | None = None, stale_after_days: int = 7) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    for path in paths:
        findings.extend(lint_path(path, today=today, stale_after_days=stale_after_days))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--today", type=date.fromisoformat, default=date.today())
    parser.add_argument("--stale-after-days", type=int, default=7)
    parser.add_argument("--strict", action="store_true", help="exit 1 when findings remain")
    args = parser.parse_args(argv)
    findings = lint_paths(args.paths, today=args.today, stale_after_days=args.stale_after_days)
    print(json.dumps({"findings": findings}, indent=2, ensure_ascii=False))
    return 1 if args.strict and findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
