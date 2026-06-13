#!/usr/bin/env python3
"""Build stable-ID ROUTE batches from reduced candidate facts.

Input:  JSON array of candidate-fact objects on stdin.
Output: JSON array of route batch objects:
  [{"batch_id":"route-0001","candidates":[{"candidate_id":"c000001","candidate":{...}}]}]

The IDs are deterministic from the reduced candidate order. Batched ROUTE agents
must echo them back so validation can prove no candidate was dropped, duplicated,
or silently mis-attributed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


REQUIRED_CANDIDATE_FIELDS = {"content", "confidence", "source_chat", "source_date"}


def die(message: str) -> int:
    print(f"build-route-batches: {message}", file=sys.stderr)
    return 1


def read_json_stdin() -> Any:
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON input: {exc}") from exc


def parse_positive_int(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if parsed < 1:
        raise ValueError(f"{name} must be >= 1")
    return parsed


def candidate_id(index: int) -> str:
    return f"c{index + 1:06d}"


def validate_candidate(candidate: Any, index: int) -> None:
    if not isinstance(candidate, dict):
        raise ValueError(f"candidate #{index + 1} is not an object")
    missing = sorted(REQUIRED_CANDIDATE_FIELDS - set(candidate))
    if missing:
        raise ValueError(f"candidate #{index + 1} missing required fields: {', '.join(missing)}")


def build_batches(candidates: list[dict[str, Any]], size: int) -> list[dict[str, Any]]:
    annotated = [
        {"candidate_id": candidate_id(i), "candidate": candidate}
        for i, candidate in enumerate(candidates)
    ]
    return [
        {
            "batch_id": f"route-{(start // size) + 1:04d}",
            "candidates": annotated[start : start + size],
        }
        for start in range(0, len(annotated), size)
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build dream-skill ROUTE batches.")
    parser.add_argument(
        "--size",
        default=os.environ.get("DREAM_ROUTE_BATCH_SIZE", "25"),
        # A/B validated 2026-06-13: at 25, ROUTE cost was ~2010 tok/candidate vs
        # ~2879 at 15 (the shared nav-context + ROUTING.md is re-read once per batch,
        # so fewer, larger batches amortize it) — ~30% cheaper with routing quality
        # unchanged. 25 keeps per-agent attention sound; do not push much past this.
        help="maximum candidates per route agent batch (default: 25)",
    )
    args = parser.parse_args(argv)

    try:
        size = parse_positive_int(args.size, "--size")
        payload = read_json_stdin()
        if not isinstance(payload, list):
            return die("input must be a JSON array of candidate facts")
        for index, candidate in enumerate(payload):
            validate_candidate(candidate, index)
        batches = build_batches(payload, size)
    except ValueError as exc:
        return die(str(exc))

    json.dump(batches, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
