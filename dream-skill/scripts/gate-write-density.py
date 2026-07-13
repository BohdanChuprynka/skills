#!/usr/bin/env python3
"""Make concentrated Dream writes review-only without dropping information.

Input is the validated RECONCILE record array.  Only otherwise-auto-writable
``new`` decisions are considered.  The gate is deterministic in input order and
annotates, rather than removes, overflow decisions.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from vault_search import load_vault_config


def nonnegative(value: str, flag: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{flag} must be an integer") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError(f"{flag} must be >= 0")
    return parsed


def gate(
    records: list[dict[str, Any]],
    roots: dict[str, tuple[Path, str]],
    page_limit: int,
    section_limit: int,
    page_line_threshold: int,
) -> tuple[list[dict[str, Any]], Counter[str]]:
    page_counts: Counter[tuple[str, str]] = Counter()
    section_counts: Counter[tuple[str, str, str]] = Counter()
    reasons: Counter[str] = Counter()
    output: list[dict[str, Any]] = []

    for record in records:
        enriched_record = dict(record)
        decision = dict(record.get("decision") or {})
        enriched_record["decision"] = decision
        output.append(enriched_record)
        if decision.get("action") != "new" or decision.get("needs_review") is True:
            continue
        target = decision.get("target") if isinstance(decision.get("target"), dict) else {}
        vault = str(target.get("vault") or "")
        page = str(target.get("page") or "")
        section = str(target.get("section") or "")
        if not vault or not page or vault not in roots:
            continue

        page_key = (vault, page)
        section_key = (vault, page, section)
        page_counts[page_key] += 1
        section_counts[section_key] += 1
        triggered: list[str] = []

        page_path = roots[vault][0] / page
        if page_line_threshold and page_path.is_file():
            try:
                line_count = sum(1 for _ in page_path.open(encoding="utf-8", errors="ignore"))
            except OSError:
                line_count = 0
            if line_count >= page_line_threshold:
                triggered.append("existing_page_too_large")
                decision["target_page_lines"] = line_count
        if page_limit and page_counts[page_key] > page_limit:
            triggered.append("run_page_limit")
        if section_limit and section_counts[section_key] > section_limit:
            triggered.append("run_section_limit")

        if triggered:
            decision["needs_review"] = True
            decision["density_review"] = True
            decision["density_reasons"] = triggered
            for reason in triggered:
                reasons[reason] += 1

    return output, reasons


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--page-limit", default="12")
    parser.add_argument("--section-limit", default="8")
    parser.add_argument("--page-line-threshold", default="1000")
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args(argv)
    try:
        page_limit = nonnegative(args.page_limit, "--page-limit")
        section_limit = nonnegative(args.section_limit, "--section-limit")
        page_line_threshold = nonnegative(args.page_line_threshold, "--page-line-threshold")
        payload = json.load(sys.stdin)
        if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
            raise ValueError("input must be an array of decision records")
        roots = load_vault_config(args.config)
        output, reasons = gate(
            payload,
            roots,
            page_limit=page_limit,
            section_limit=section_limit,
            page_line_threshold=page_line_threshold,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"gate-write-density: {exc}", file=sys.stderr)
        return 1
    if args.report:
        detail = ",".join(f"{key}:{reasons[key]}" for key in sorted(reasons)) or "none"
        print(f"gate-write-density: in={len(payload)} gated={sum(1 for r in output if (r.get('decision') or {}).get('density_review'))} reasons={detail}", file=sys.stderr)
    json.dump(output, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
