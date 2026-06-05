#!/usr/bin/env python3
"""Prefilter Claude Code JSONL transcripts for dream-skill MAP agents.

The output is intentionally plain text:
  USER: human-entered text
  ASST: assistant user-facing text

Tool payloads, internal thinking, command wrappers, attachments, and metadata are
discarded before an extraction agent sees the transcript.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SYSTEM_REMINDER_BLOCK = re.compile(
    r"<system-reminder>.*?</system-reminder>",
    re.DOTALL | re.IGNORECASE,
)
REMOVABLE_USER_BLOCKS = [
    re.compile(
        r"<local-command-([a-z-]+)>.*?</local-command-\1>",
        re.DOTALL | re.IGNORECASE,
    ),
    re.compile(
        r"<ide_selection>.*?</ide_selection>",
        re.DOTALL | re.IGNORECASE,
    ),
    re.compile(
        r"<task-notification>.*?</task-notification>",
        re.DOTALL | re.IGNORECASE,
    ),
]
COMMAND_TAG_BLOCK = re.compile(
    r"\s*<command-(message|name|args)>.*?</command-\1>\s*",
    re.DOTALL | re.IGNORECASE,
)


def event_role(evt: dict[str, Any]) -> str | None:
    msg = evt.get("message")
    role = msg.get("role") if isinstance(msg, dict) else None
    role = role or evt.get("role") or evt.get("type")
    return role if role in {"user", "assistant"} else None


def event_content(evt: dict[str, Any]) -> Any:
    msg = evt.get("message")
    if isinstance(msg, dict):
        return msg.get("content")
    return evt.get("content")


def extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") != "text":
            continue
        text = block.get("text", "")
        if isinstance(text, str) and text.strip():
            parts.append(text.strip())
    return "\n".join(parts).strip()


def is_pure_command_wrapper(text: str) -> bool:
    stripped = text.strip()
    if not stripped or "<command-" not in stripped.lower():
        return False
    return COMMAND_TAG_BLOCK.sub("", stripped).strip() == ""


def clean_user_text(text: str) -> str:
    cleaned = SYSTEM_REMINDER_BLOCK.sub("", text)
    for pattern in REMOVABLE_USER_BLOCKS:
        cleaned = pattern.sub("", cleaned)
    if is_pure_command_wrapper(cleaned):
        return ""
    return cleaned.strip()


def iter_filtered_lines(path: Path) -> tuple[list[str], dict[str, int]]:
    stats = {
        "raw_lines": 0,
        "parsed_events": 0,
        "malformed_lines": 0,
        "emitted_lines": 0,
        "skipped_events": 0,
    }
    out: list[str] = []

    with path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            stats["raw_lines"] += 1
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                stats["malformed_lines"] += 1
                continue
            if not isinstance(evt, dict):
                stats["skipped_events"] += 1
                continue

            stats["parsed_events"] += 1
            if evt.get("isMeta") or evt.get("isCompactSummary"):
                stats["skipped_events"] += 1
                continue
            origin = evt.get("origin")
            if isinstance(origin, dict) and origin.get("kind") == "task-notification":
                stats["skipped_events"] += 1
                continue

            role = event_role(evt)
            if role is None:
                stats["skipped_events"] += 1
                continue

            text = extract_text(event_content(evt))
            if not text:
                stats["skipped_events"] += 1
                continue

            if role == "user":
                text = clean_user_text(text)
                if not text:
                    stats["skipped_events"] += 1
                    continue
                out.append(f"USER: {text}")
            else:
                out.append(f"ASST: {text}")
            stats["emitted_lines"] += 1

    return out, stats


def main() -> int:
    parser = argparse.ArgumentParser(description="Filter one Claude Code JSONL transcript.")
    parser.add_argument("transcript", type=Path)
    parser.add_argument("--stats", action="store_true", help="Write one summary line to stderr.")
    args = parser.parse_args()

    try:
        raw_bytes = args.transcript.stat().st_size
    except OSError as exc:
        print(f"prefilter-transcript: cannot stat {args.transcript}: {exc}", file=sys.stderr)
        return 1

    try:
        lines, stats = iter_filtered_lines(args.transcript)
    except OSError as exc:
        print(f"prefilter-transcript: cannot read {args.transcript}: {exc}", file=sys.stderr)
        return 1

    output_bytes = 0
    for line in lines:
        rendered = f"{line}\n"
        output_bytes += len(rendered.encode("utf-8"))
        sys.stdout.write(rendered)

    if args.stats:
        print(
            "prefilter_stats"
            f" raw_bytes={raw_bytes}"
            f" output_bytes={output_bytes}"
            f" raw_lines={stats['raw_lines']}"
            f" parsed_events={stats['parsed_events']}"
            f" emitted_lines={stats['emitted_lines']}"
            f" skipped_events={stats['skipped_events']}"
            f" malformed_lines={stats['malformed_lines']}",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
