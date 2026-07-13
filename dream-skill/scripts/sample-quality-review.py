#!/usr/bin/env python3
"""Deterministically send a percentage of high-confidence facts through review."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from typing import Any


def die(message: str) -> int:
    print(f"sample-quality-review: {message}", file=sys.stderr)
    return 1


def sample_bucket(candidate: dict[str, Any]) -> int:
    identity = {
        key: candidate.get(key)
        for key in ("content", "source_chat", "source_date", "source_event")
    }
    canonical = json.dumps(identity, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return int(hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:8], 16) % 100


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--percent", type=int, default=0)
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args(argv)
    if not 0 <= args.percent <= 100:
        return die("--percent must be between 0 and 100")
    try:
        candidates = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        return die(f"invalid JSON: {exc}")
    if not isinstance(candidates, list):
        return die("input must be a JSON array")

    sampled = 0
    output: list[dict[str, Any]] = []
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            return die(f"candidate #{index + 1} is not an object")
        item = dict(candidate)
        bucket = sample_bucket(item)
        if item.get("confidence") == "high" and bucket < args.percent:
            item["original_confidence"] = "high"
            item["confidence"] = "medium"
            item["quality_review_sample"] = True
            item["quality_review_bucket"] = bucket
            sampled += 1
        output.append(item)

    if args.report:
        print(
            f"sample-quality-review: in={len(candidates)} sampled={sampled} percent={args.percent}",
            file=sys.stderr,
        )
    json.dump(output, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
