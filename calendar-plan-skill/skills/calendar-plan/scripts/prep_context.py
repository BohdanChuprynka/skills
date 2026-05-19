#!/usr/bin/env python3
"""prep_context.py — render the cron-prompt template with placeholders filled.

No LLM call. Pure substitution. Reads:
  - prompts/cron-prompt.md (template, with `{{PLACEHOLDER}}` tokens)
  - target date, timezone, paths

Writes the rendered prompt to --out.

The rendered prompt is consumed by the next stage:
    claude --mcp-config ... -p "@<rendered-prompt>"
"""
from __future__ import annotations

import argparse
import pathlib
import sys


PLACEHOLDERS = (
    "SKILL_DIR",
    "PLANNING_PREFS",
    "MEMORY_FILE",
    "CALENDAR_CONTEXT",
    "TASK_SOURCE_NAME",
    "TIMEZONE",
    "CRON_HOUR",
    "TARGET_DATE",
    "MODE",
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--template", required=True, type=pathlib.Path)
    p.add_argument("--out", required=True, type=pathlib.Path)
    for ph in PLACEHOLDERS:
        p.add_argument(f"--{ph.lower().replace('_', '-')}", default="")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    template = args.template.read_text(encoding="utf-8")

    values = {ph: getattr(args, ph.lower()) for ph in PLACEHOLDERS}

    # Strip the doc-header (everything above the first `---` separator in the template).
    # The template has explanatory frontmatter for humans; the LLM only needs the body.
    if "\n---\n" in template:
        body = template.split("\n---\n", 1)[1]
    else:
        body = template

    # Prepend a short run header so the model sees target_date/mode up front.
    run_header = (
        f"# Run context\n\n"
        f"- target_date: {values['TARGET_DATE']}\n"
        f"- timezone: {values['TIMEZONE']}\n"
        f"- mode: {values['MODE']}\n\n"
        f"---\n\n"
    )

    rendered = body
    for ph, val in values.items():
        rendered = rendered.replace("{{" + ph + "}}", val)

    # Sanity: no placeholder should remain unresolved
    leftover = [ph for ph in PLACEHOLDERS if "{{" + ph + "}}" in rendered]
    if leftover:
        print(f"WARN: unresolved placeholders: {leftover}", file=sys.stderr)

    args.out.write_text(run_header + rendered, encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
