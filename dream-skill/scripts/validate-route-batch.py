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
import os
import re
import sys
from pathlib import Path
from typing import Any

from vault_search import build_page_docs


STATUSES = {"routed", "ambiguous", "gap"}
CONFIDENCES = {"high", "medium", "low"}
ROUTE_KEYS = ("status", "vault", "page", "section", "routing_confidence")
OUTPUT_KEYS = {"candidate_id", *ROUTE_KEYS}
EXCLUDED_PAGE_NAMES = {"AGENTS.md", "CLAUDE.md", "index.md"}


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


def parse_vault_roots(config_path: Path) -> dict[str, Path]:
    if not config_path.is_file():
        raise ValueError(f"config not found: {config_path}")

    roots: dict[str, Path] = {}
    current: str | None = None
    section_re = re.compile(r"^\s*\[vaults\.([A-Za-z0-9_-]+)\]\s*$")
    any_section_re = re.compile(r"^\s*\[")
    root_re = re.compile(r'^\s*root\s*=\s*"([^"]+)"')

    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        section = section_re.match(raw_line)
        if section:
            current = section.group(1)
            continue
        if any_section_re.match(raw_line):
            current = None
            continue
        if current:
            root = root_re.match(raw_line)
            if root:
                roots[current] = Path(os.path.expanduser(root.group(1))).resolve()

    return roots


def is_content_page(path: Path) -> bool:
    if path.name in EXCLUDED_PAGE_NAMES:
        return False
    if path.suffix.lower() != ".md":
        return False
    if any(part.startswith(".") for part in path.parts):
        return False
    if "Attachments" in path.parts:
        return False
    return True


def canonical_pages_for_vault(root: Path) -> set[str]:
    if not root.is_dir():
        raise ValueError(f"vault root not found: {root}")
    # Generated-wiki vaults use wiki/ as the canonical routing surface. Vaults
    # without wiki/ expose their markdown tree (for example personal-notes).
    scan_root = root / "wiki" if (root / "wiki").is_dir() else root
    pages: set[str] = set()
    for path in scan_root.rglob("*.md"):
        if not is_content_page(path):
            continue
        resolved = path.resolve()
        try:
            rel = resolved.relative_to(root)
        except ValueError as exc:
            raise ValueError(f"page escapes vault root: {path}") from exc
        pages.add(rel.as_posix())
    return pages


def build_canonical_pages(roots: dict[str, Path], config_path: Path) -> dict[str, set[str]]:
    pages = {vault: set() for vault in roots}
    for doc in build_page_docs(config_path):
        if doc.vault in pages:
            pages[doc.vault].add(doc.page)
    return pages


def safe_relative_page(page: str) -> str:
    page_path = Path(page)
    if page_path.is_absolute() or ".." in page_path.parts:
        raise ValueError(f"unsafe routed page path: {page}")
    return page_path.as_posix()


def resolve_canonical_page(vault: str, page: str, canonical_pages: dict[str, set[str]]) -> str | None:
    pages = canonical_pages.get(vault)
    if pages is None:
        return None

    rel = safe_relative_page(page)
    if rel in pages:
        return rel

    wiki_rel = f"wiki/{rel}"
    if wiki_rel in pages:
        return wiki_rel

    page_name = Path(rel).name
    matches = sorted(candidate for candidate in pages if Path(candidate).name == page_name)
    if len(matches) == 1:
        return matches[0]
    return None


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


def validate_route(
    route: dict[str, Any],
    canonical_pages: dict[str, set[str]] | None = None,
    missing_page_policy: str = "error",
) -> None:
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
        if canonical_pages is not None:
            vault = route["vault"]
            page = route["page"]
            canonical_page = resolve_canonical_page(vault, page, canonical_pages)
            if canonical_page is None:
                if missing_page_policy == "gap":
                    print(
                        f"validate-route-batch: {candidate_id}: missing canonical page "
                        f"{vault}/{page}; converting route to gap",
                        file=sys.stderr,
                    )
                    route["status"] = "gap"
                    route["vault"] = None
                    route["page"] = None
                    route["section"] = None
                    route["routing_confidence"] = "low"
                    return
                raise ValueError(f"{candidate_id}: routed page is not canonical or does not exist: {vault}/{page}")
            route["page"] = canonical_page
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
    parser.add_argument(
        "--config",
        help="dream-skill config.toml; when set, routed pages must exist in the canonical page index",
    )
    parser.add_argument(
        "--missing-page-policy",
        choices=("error", "gap"),
        default="error",
        help="how to handle routed pages not found in the canonical page index (default: error)",
    )
    args = parser.parse_args(argv)

    try:
        canonical_pages = None
        if args.config:
            config_path = Path(args.config)
            canonical_pages = build_canonical_pages(parse_vault_roots(config_path), config_path)
        batch = load_json_file(args.batch)
        inputs = validate_batch(batch)
        output = read_json_stdin()
        if isinstance(output, dict) and isinstance(output.get("routes"), list):
            output = output["routes"]
        if not isinstance(output, list):
            return die("route output must be a JSON array, or an object with a routes array")

        routes = [normalize_route(record) for record in output]
        for route in routes:
            validate_route(route, canonical_pages, args.missing_page_policy)

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
        input_by_id = {item["candidate_id"]: item for item in inputs}
        catalog = {
            row.get("page_id"): (row.get("vault"), row.get("page"))
            for row in (batch.get("page_catalog") or [])
            if isinstance(row, dict)
        }
        for candidate_id, route in route_by_id.items():
            allowed_ids = input_by_id[candidate_id].get("allowed_page_ids")
            if route["status"] != "routed" or not isinstance(allowed_ids, list):
                continue
            allowed = {catalog[page_id] for page_id in allowed_ids if page_id in catalog}
            if (route["vault"], route["page"]) not in allowed:
                if args.missing_page_policy == "gap":
                    print(
                        f"validate-route-batch: {candidate_id}: route outside retrieved page candidates; converting to gap",
                        file=sys.stderr,
                    )
                    route.update(
                        status="gap",
                        vault=None,
                        page=None,
                        section=None,
                        routing_confidence="low",
                    )
                else:
                    raise ValueError(
                        f"{candidate_id}: routed target was not present in page_candidates"
                    )
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
