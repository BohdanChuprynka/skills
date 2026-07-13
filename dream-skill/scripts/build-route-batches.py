#!/usr/bin/env python3
"""Build stable-ID ROUTE batches from reduced candidate facts.

Input:  JSON array of candidate-fact objects on stdin.
Output: JSON array of route batch objects:
  [{"batch_id":"route-0001","candidates":[{"candidate_id":"c000001","candidate":{...}}]}]

The IDs are deterministic hashes of canonical candidate content. Batched ROUTE agents
must echo them back so validation can prove no candidate was dropped, duplicated,
or silently mis-attributed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from candidate_identity import candidate_id
from vault_search import PageSearch, build_page_docs


REQUIRED_CANDIDATE_FIELDS = {"content", "confidence", "source_chat", "source_date", "memory_tier"}


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


def validate_candidate(candidate: Any, index: int) -> None:
    if not isinstance(candidate, dict):
        raise ValueError(f"candidate #{index + 1} is not an object")
    missing = sorted(REQUIRED_CANDIDATE_FIELDS - set(candidate))
    if missing:
        raise ValueError(f"candidate #{index + 1} missing required fields: {', '.join(missing)}")


def build_batches(
    candidates: list[dict[str, Any]],
    size: int,
    search: PageSearch | None = None,
    top_k: int = 32,
) -> list[dict[str, Any]]:
    annotated = [
        {
            "candidate_id": candidate_id(candidate),
            "candidate": candidate,
            **(
                {
                    "page_candidates": search.search(
                        " ".join(
                            str(candidate.get(key) or "")
                            for key in ("content", "suggested_section", "type")
                        ),
                        limit=top_k,
                    )
                }
                if search is not None
                else {}
            ),
        }
        for candidate in candidates
    ]
    ids = [item["candidate_id"] for item in annotated]
    duplicate_ids = sorted(candidate_id for candidate_id, count in Counter(ids).items() if count > 1)
    if duplicate_ids:
        raise ValueError(
            "duplicate candidates remain after REDUCE (stable IDs collide): "
            + ", ".join(duplicate_ids)
        )
    batches: list[dict[str, Any]] = []
    for start in range(0, len(annotated), size):
        chunk = annotated[start : start + size]
        catalog_rows: list[dict[str, Any]] = []
        catalog_ids: dict[tuple[str, str], str] = {}
        compact_candidates: list[dict[str, Any]] = []
        for item in chunk:
            allowed_ids: list[str] = []
            for row in item.pop("page_candidates", []):
                key = (row["vault"], row["page"])
                page_id = catalog_ids.get(key)
                if page_id is None:
                    page_id = f"p{len(catalog_rows) + 1:03d}"
                    catalog_ids[key] = page_id
                    catalog_rows.append(
                        {
                            "page_id": page_id,
                            "vault": row["vault"],
                            "page": row["page"],
                            "title": row["title"],
                            "headings": row["headings"][:6],
                            "retrieval_score": row.get("score"),
                        }
                    )
                allowed_ids.append(page_id)
            compact = dict(item)
            if search is not None:
                compact["allowed_page_ids"] = allowed_ids
            compact_candidates.append(compact)
        batch: dict[str, Any] = {
            "batch_id": f"route-{(start // size) + 1:04d}",
            "candidates": compact_candidates,
        }
        if search is not None:
            batch["page_catalog"] = catalog_rows
        batches.append(batch)
    return batches


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build dream-skill ROUTE batches.")
    parser.add_argument(
        "--size",
        default=os.environ.get("DREAM_ROUTE_BATCH_SIZE", "25"),
        # Batches amortize the routing contract and bounded page catalog while
        # keeping enough per-candidate attention for disambiguation.
        help="maximum candidates per route agent batch (default: 25)",
    )
    parser.add_argument("--config", type=Path, help="config.toml used to attach local page candidates")
    parser.add_argument(
        "--top-k",
        default=os.environ.get("DREAM_ROUTE_TOP_K", "32"),
        help="maximum canonical page candidates attached to each fact (default: 32)",
    )
    args = parser.parse_args(argv)

    try:
        size = parse_positive_int(args.size, "--size")
        top_k = parse_positive_int(args.top_k, "--top-k")
        payload = read_json_stdin()
        if not isinstance(payload, list):
            return die("input must be a JSON array of candidate facts")
        for index, candidate in enumerate(payload):
            validate_candidate(candidate, index)
        search = PageSearch(build_page_docs(args.config)) if args.config else None
        batches = build_batches(payload, size, search=search, top_k=top_k)
    except ValueError as exc:
        return die(str(exc))

    json.dump(batches, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
