#!/usr/bin/env python3
"""Make stale current-state candidates review-only without dropping content.

Historical backfills can surface operational facts that were true when stated but
must not silently become present-tense wiki truth months later. This gate keeps
every candidate, but lowers stale ``memory_tier=current`` candidates to medium
confidence and annotates them for review. The existing RECONCILE validator then
requires ``needs_review=true`` for any new fact.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from typing import Any


def die(message: str) -> int:
    print(f"gate-historical-current: {message}", file=sys.stderr)
    return 1


def parse_iso_date(raw: Any, label: str) -> date:
    if not isinstance(raw, str):
        raise ValueError(f"{label} must be YYYY-MM-DD")
    try:
        return date.fromisoformat(raw)
    except ValueError as exc:
        raise ValueError(f"{label} must be YYYY-MM-DD: {raw!r}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--as-of", required=True, help="comparison date, YYYY-MM-DD")
    parser.add_argument(
        "--review-after-days",
        type=int,
        default=30,
        help="review current facts this many days old or older; 0 reviews all current facts",
    )
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args(argv)

    if args.review_after_days < 0:
        return die("--review-after-days must be >= 0")
    try:
        as_of = parse_iso_date(args.as_of, "--as-of")
        candidates = json.load(sys.stdin)
    except (ValueError, json.JSONDecodeError) as exc:
        return die(str(exc))
    if not isinstance(candidates, list):
        return die("input must be a JSON array")

    gated = 0
    output: list[dict[str, Any]] = []
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            return die(f"candidate #{index + 1} is not an object")
        item = dict(candidate)
        if item.get("memory_tier") == "current":
            try:
                source_date = parse_iso_date(item.get("source_date"), f"candidate #{index + 1} source_date")
            except ValueError as exc:
                return die(str(exc))
            age_days = (as_of - source_date).days
            if age_days >= args.review_after_days:
                item["historical_review"] = True
                item["historical_age_days"] = age_days
                if item.get("confidence") == "high":
                    item["original_confidence"] = "high"
                    item["confidence"] = "medium"
                gated += 1
        output.append(item)

    if args.report:
        print(
            f"gate-historical-current: in={len(candidates)} gated={gated} "
            f"review_after_days={args.review_after_days} as_of={as_of.isoformat()}",
            file=sys.stderr,
        )
    json.dump(output, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
