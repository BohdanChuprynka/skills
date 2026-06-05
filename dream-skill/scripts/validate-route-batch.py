#!/usr/bin/env python3
"""Validate one batched ROUTE agent output and join it back to candidates.

Input:
  --batch <route-batch.json>  The batch created by build-route-batches.py.
  stdin                       The agent's JSON array output.

Accepted agent output shape:
  [
    {
      "candidate_id": "c000001",
      "status": "routed",
      "vault": "me",
      "page": "wiki/bio.md",
      "section": "Bio",
      "routing_confidence": "high"
    }
  ]

Output:
  [
    {
      "candidate_id": "c000001",
      "candidate": {...},
      "route": {"status":"routed", ...}
    }
  ]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


STATUSES = {"routed", "ambiguous", "gap"}
CONFIDENCES = {"high", "medium", "low"}
ROUTE_KEYS = ("status", "vault", "page", "section", "routing_confidence")
OUTPUT_KEYS = {"candidate_id", *ROUTE_KEYS}


def die(message: str) -> int:
    print(f"validate-route-batch: {message}", file=sys.stderr)
    return 1


def load_json_file(path: str) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"batch file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"batch file is not valid JSON: {exc}") from exc


def read_json_stdin() -> Any:
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise ValueError(f"route output is not valid JSON: {exc}") from exc


def normalize_route(record: Any) -> dict[str, Any]:
    if not isinstance(record, dict):
        raise ValueError("route output item is not an object")
    if "routing" in record:
        allowed = {"candidate_id", "routing"}
        extras = sorted(set(record) - allowed)
        if extras:
            raise ValueError("route output wrapper has unexpected keys: " + ", ".join(extras))
        route = record["routing"]
        if not isinstance(route, dict):
            raise ValueError("route output .routing is not an object")
        normalized = dict(route)
        normalized["candidate_id"] = record.get("candidate_id")
        return normalized
    return dict(record)


def validate_route(route: dict[str, Any]) -> None:
    candidate_id = route.get("candidate_id")
    if not isinstance(candidate_id, str) or not candidate_id:
        raise ValueError("route output item missing candidate_id")

    missing = sorted(OUTPUT_KEYS - set(route))
    if missing:
        raise ValueError(f"{candidate_id}: route output missing keys: {', '.join(missing)}")
    extras = sorted(set(route) - OUTPUT_KEYS)
    if extras:
        raise ValueError(f"{candidate_id}: route output has unexpected keys: {', '.join(extras)}")

    status = route.get("status")
    if status not in STATUSES:
        raise ValueError(f"{candidate_id}: invalid status {status!r}")

    confidence = route.get("routing_confidence")
    if confidence not in CONFIDENCES:
        raise ValueError(f"{candidate_id}: invalid routing_confidence {confidence!r}")

    if status == "routed":
        for key in ("vault", "page", "section"):
            if not isinstance(route.get(key), str) or not route[key].strip():
                raise ValueError(f"{candidate_id}: routed decision requires non-empty {key}")
    else:
        for key in ("vault", "page", "section"):
            if route.get(key) is not None:
                raise ValueError(f"{candidate_id}: {status} decision requires {key}=null")


def validate_batch(batch: Any) -> list[dict[str, Any]]:
    if not isinstance(batch, dict):
        raise ValueError("batch must be a JSON object")
    candidates = batch.get("candidates")
    if not isinstance(candidates, list):
        raise ValueError("batch missing candidates array")
    seen: set[str] = set()
    for item in candidates:
        if not isinstance(item, dict):
            raise ValueError("batch candidate item is not an object")
        candidate_id = item.get("candidate_id")
        if not isinstance(candidate_id, str) or not candidate_id:
            raise ValueError("batch candidate item missing candidate_id")
        if candidate_id in seen:
            raise ValueError(f"duplicate candidate_id in batch: {candidate_id}")
        if not isinstance(item.get("candidate"), dict):
            raise ValueError(f"{candidate_id}: missing candidate object")
        seen.add(candidate_id)
    return candidates


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate one dream-skill ROUTE batch output.")
    parser.add_argument("--batch", required=True, help="route batch JSON file")
    args = parser.parse_args(argv)

    try:
        batch = load_json_file(args.batch)
        inputs = validate_batch(batch)
        output = read_json_stdin()
        if isinstance(output, dict) and isinstance(output.get("routes"), list):
            output = output["routes"]
        if not isinstance(output, list):
            return die("route output must be a JSON array, or an object with a routes array")

        routes = [normalize_route(record) for record in output]
        for route in routes:
            validate_route(route)

        input_ids = [item["candidate_id"] for item in inputs]
        route_ids = [route["candidate_id"] for route in routes]
        duplicate_route_ids = sorted({candidate_id for candidate_id in route_ids if route_ids.count(candidate_id) > 1})
        if duplicate_route_ids:
            raise ValueError(f"duplicate candidate_id in route output: {', '.join(duplicate_route_ids)}")
        if sorted(input_ids) != sorted(route_ids):
            missing = sorted(set(input_ids) - set(route_ids))
            extra = sorted(set(route_ids) - set(input_ids))
            detail = []
            if missing:
                detail.append("missing " + ", ".join(missing))
            if extra:
                detail.append("extra " + ", ".join(extra))
            raise ValueError("route output candidate_id mismatch: " + "; ".join(detail))

        route_by_id = {route["candidate_id"]: route for route in routes}
        joined = []
        for item in inputs:
            route = route_by_id[item["candidate_id"]]
            joined.append(
                {
                    "candidate_id": item["candidate_id"],
                    "candidate": item["candidate"],
                    "route": {key: route.get(key) for key in ROUTE_KEYS},
                }
            )
    except ValueError as exc:
        return die(str(exc))

    json.dump(joined, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
