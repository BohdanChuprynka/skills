#!/usr/bin/env python3
"""Split REDUCE output into routable, audit, and dropped candidates by memory_tier.

Runs immediately after reduce-dedup.py and before build-route-batches.py, so
operational telemetry (commit hashes, test counts, file churn) never reaches
build-route-batches.py, ROUTE, RECONCILE, or a vault write.

Input  (stdin):  JSON array of candidate-fact objects, each carrying a
                  validated memory_tier (stable|current|audit|drop).
Output (stdout): a single JSON object:
  {"routable": [...], "audit": [...], "dropped": N}

  routable = candidates with memory_tier in {stable, current}, original order.
  audit    = candidates with memory_tier == audit, original order (retained
             for the receipt, never routed or written to a vault).
  dropped  = count of candidates with memory_tier == drop. Their content is
             discarded entirely — not retained anywhere, not even in audit.

By the time this script runs, validate-candidates.py has already guaranteed
every candidate carries a valid memory_tier. The check here is defensive,
not the primary enforcement point.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

ROUTABLE_TIERS = {"stable", "current"}


def die(message: str) -> int:
    print(f"split-memory-tiers: {message}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="write a one-line split report to stderr")
    args = parser.parse_args(argv)

    try:
        pool = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        return die(f"invalid JSON: {exc}")
    if not isinstance(pool, list):
        return die("input must be a JSON array")

    routable: list[dict[str, Any]] = []
    audit: list[dict[str, Any]] = []
    dropped = 0

    for index, candidate in enumerate(pool):
        if not isinstance(candidate, dict):
            return die(f"candidate #{index + 1} is not an object")
        tier = candidate.get("memory_tier")
        if tier in ROUTABLE_TIERS:
            routable.append(candidate)
        elif tier == "audit":
            audit.append(candidate)
        elif tier == "drop":
            dropped += 1
        else:
            return die(f"candidate #{index + 1} has missing or invalid memory_tier: {tier!r}")

    if args.report:
        print(
            f"split-memory-tiers: in={len(pool)} routable={len(routable)} "
            f"audit={len(audit)} dropped={dropped}",
            file=sys.stderr,
        )

    json.dump({"routable": routable, "audit": audit, "dropped": dropped}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
