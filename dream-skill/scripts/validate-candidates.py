#!/usr/bin/env python3
"""Validate MAP candidates, including exact evidence provenance when a unit is supplied."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path
from typing import Any


CONFIDENCES = {"high", "medium", "low"}
SOURCE_ROLES = {"user", "user_confirmation", "assistant_context"}
TIERS = {"stable", "current", "audit", "drop"}
MAX_CONTENT_CHARS = 320
REQUIRED = {
    "content",
    "confidence",
    "source_chat",
    "source_date",
    "source_role",
    "source_event",
    "evidence",
    "memory_tier",
}
FORBIDDEN = {"needs_review", "target_hint", "section"}
EVENT_RE = re.compile(r"^(USER|ASST)\[(\d+)\]:\s?(.*)$")
SEPARATOR_RE = re.compile(r"^===== DREAM-MAP-UNIT source_chat=(.*?) source_date=.*? =====$")


def normalize_space(value: str) -> str:
    return " ".join(value.split()).casefold()


def parse_events(path: Path, default_chat: str | None) -> dict[tuple[str, int], tuple[str, str]]:
    events: dict[tuple[str, int], tuple[str, str]] = {}
    current_chat = default_chat or ""
    current_key: tuple[str, int] | None = None
    current_role = ""
    current_lines: list[str] = []

    def flush() -> None:
        nonlocal current_key, current_role, current_lines
        if current_key is not None:
            events[current_key] = (current_role, "\n".join(current_lines))
        current_key = None
        current_role = ""
        current_lines = []

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        separator = SEPARATOR_RE.match(line)
        if separator:
            flush()
            current_chat = separator.group(1)
            continue
        event = EVENT_RE.match(line)
        if event:
            flush()
            current_key = (current_chat, int(event.group(2)))
            current_role = "user" if event.group(1) == "USER" else "assistant"
            current_lines = [event.group(3)]
        elif current_key is not None:
            current_lines.append(line)
    flush()
    return events


def validate_candidate(
    candidate: Any,
    index: int,
    events: dict[tuple[str, int], tuple[str, str]] | None,
    default_chat: str | None,
) -> tuple[dict[str, Any] | None, str | None]:
    if not isinstance(candidate, dict):
        return None, "not an object"
    missing = sorted(REQUIRED - set(candidate))
    if missing:
        return None, "missing fields: " + ", ".join(missing)
    forbidden = sorted(FORBIDDEN & set(candidate))
    if forbidden:
        return None, "forbidden fields: " + ", ".join(forbidden)

    content = candidate.get("content")
    evidence = candidate.get("evidence")
    source_chat = candidate.get("source_chat")
    source_date = candidate.get("source_date")
    source_role = candidate.get("source_role")
    source_event = candidate.get("source_event")
    confidence = candidate.get("confidence")

    if not isinstance(content, str) or not content.strip():
        return None, "content must be a non-empty string"
    content = content.strip()
    if "\n" in content or "\r" in content or len(content) > MAX_CONTENT_CHARS:
        return None, f"content must be one line and at most {MAX_CONTENT_CHARS} characters"
    if content.startswith("- "):
        return None, "content must not include a Markdown bullet prefix"
    if not isinstance(evidence, str) or not evidence.strip():
        return None, "evidence must be a non-empty exact source span"
    evidence = evidence.strip()
    if "\n" in evidence or "\r" in evidence or len(evidence) > 160:
        return None, "evidence must be one line and at most 160 characters"
    if not isinstance(source_chat, str) or not source_chat.strip():
        return None, "source_chat must be a non-empty string"
    if confidence not in CONFIDENCES:
        return None, "invalid confidence"
    if candidate.get("memory_tier") not in TIERS:
        return None, "invalid memory_tier"
    if source_role not in SOURCE_ROLES:
        return None, "invalid source_role"
    if source_role != "user" and confidence == "high":
        return None, "only direct user evidence may be high confidence"
    if not isinstance(source_event, int) or isinstance(source_event, bool) or source_event < 1:
        return None, "source_event must be a positive integer"
    if not isinstance(source_date, str):
        return None, "source_date must be an ISO date"
    try:
        date.fromisoformat(source_date)
    except ValueError:
        return None, "source_date must be an ISO date"

    if events is not None:
        event_key = (default_chat or source_chat, source_event)
        event = events.get(event_key)
        if event is None and default_chat is None:
            event = events.get((source_chat, source_event))
        if event is None:
            return None, "source_event does not exist for source_chat in the MAP unit"
        event_role, event_text = event
        expected_role = "assistant" if source_role == "assistant_context" else "user"
        if event_role != expected_role:
            return None, "source_role does not match the referenced MAP event"
        if normalize_space(evidence) not in normalize_space(event_text):
            return None, "evidence is not an exact span of the referenced MAP event"

    normalized = dict(candidate)
    normalized["content"] = content
    normalized["evidence"] = evidence
    return normalized, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit", type=Path)
    parser.add_argument("--source-chat")
    args = parser.parse_args(argv)
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"validate-candidates: invalid JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(payload, list):
        print("validate-candidates: input must be a JSON array", file=sys.stderr)
        return 1

    events = None
    if args.unit:
        if not args.unit.is_file():
            print(f"validate-candidates: unit not found: {args.unit}", file=sys.stderr)
            return 1
        events = parse_events(args.unit, args.source_chat)

    valid: list[dict[str, Any]] = []
    for index, candidate in enumerate(payload):
        normalized, reason = validate_candidate(candidate, index, events, args.source_chat)
        if normalized is None:
            print(f"validate-candidates: drop candidate #{index + 1}: {reason}", file=sys.stderr)
        else:
            valid.append(normalized)
    json.dump(valid, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
