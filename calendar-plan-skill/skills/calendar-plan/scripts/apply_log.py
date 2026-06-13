#!/usr/bin/env python3
"""apply_log.py — append a run summary to memory.md.

Parses the claude run log for created/changed/pause events and writes one
append-only block in the format documented in examples/memory.example.md.

This script does NOT make destructive edits to memory.md. It only appends.
"""
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import sys


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--memory-file", required=True, type=pathlib.Path)
    p.add_argument("--run-log", required=True, type=pathlib.Path)
    p.add_argument("--target-date", required=True)
    p.add_argument("--mode", required=True)
    p.add_argument("--timezone", required=True)
    return p.parse_args()


# Capture the text between the verb and the time so the memory line records WHAT
# happened (the event), not a bare "?" placeholder.
CREATED_RE = re.compile(r"\b(created?|added?)\b(.{0,80}?)(\d{1,2}:\d{2})", re.IGNORECASE)
CHANGED_RE = re.compile(r"\b(updated?|changed?|moved?)\b(.{0,80}?)(\d{1,2}:\d{2})", re.IGNORECASE)
PAUSE_RE = re.compile(r"\b(pause(?:d)?|skipping|not writing|waiting on)\b", re.IGNORECASE)
CONNECTOR_RE = re.compile(
    r"(notion|gmail|google-?calendar|filesystem)[^a-zA-Z0-9]{1,20}(ok|fail|unauthorized|missing|degraded|partial|unavailable|error)",
    re.IGNORECASE,
)


def _clean_ctx(ctx: str) -> str:
    """Tidy the text captured between a verb and a time into an event label."""
    ctx = re.sub(r"\s+", " ", ctx)
    ctx = re.sub(r"\b(at|to|on|for|the)\s*$", "", ctx, flags=re.IGNORECASE)
    ctx = ctx.strip(" :-—'\"()[]")
    return ctx or "(event)"


def build_action_lines(text: str) -> list[str]:
    """Derive the `actions_taken:` bullet lines from a run-log body.

    Heuristic prose parsing — best-effort, never destructive. Each create/change
    line records the captured event context and time rather than a placeholder.
    """
    created = CREATED_RE.findall(text)
    changed = CHANGED_RE.findall(text)
    paused = PAUSE_RE.search(text) is not None

    if not (created or changed) and paused:
        return ["- pause-no-write: planner reported a pause and did not write"]
    if not (created or changed):
        return ["- (no create/change verbs detected in log)"]

    lines: list[str] = []
    for _verb, ctx, when in created[:20]:
        lines.append(f"- created {_clean_ctx(ctx)} @ {when}")
    for _verb, ctx, when in changed[:20]:
        lines.append(f"- changed {_clean_ctx(ctx)} @ {when}")
    return lines


def main() -> int:
    args = parse_args()

    if not args.run_log.exists():
        print(f"WARN: run log {args.run_log} missing; nothing to summarise", file=sys.stderr)
        return 0

    text = args.run_log.read_text(encoding="utf-8", errors="replace")

    paused = PAUSE_RE.search(text) is not None
    connectors = {m[0].lower().replace("-", ""): m[1].lower() for m in CONNECTOR_RE.findall(text)}

    now = dt.datetime.now()
    run_id = now.strftime("run-%Y-%m-%dT%H:%M:%S")
    header = now.strftime(f"%Y-%m-%d %H:%M {args.timezone}")

    lines = [
        "",
        f"## {header} — {run_id}",
        "",
        f"target_date: {args.target_date}",
        f"mode: {args.mode}",
        f"connectors_status: {connectors or '{}'}",
        "",
        "observations:",
        f"- run log: {args.run_log}",
    ]
    if paused:
        lines.append("- planner paused at least once (see log for reason)")
    lines.append("")
    lines.append("actions_taken:")
    lines.extend(build_action_lines(text))

    lines.append("")

    with args.memory_file.open("a", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"appended {len(lines)} lines to {args.memory_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
