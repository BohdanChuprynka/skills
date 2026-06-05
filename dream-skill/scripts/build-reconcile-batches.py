#!/usr/bin/env python3
"""Build page-grouped RECONCILE batches from validated ROUTE results.

Input: JSON array emitted by validate-route-batch.py, usually merged across all
ROUTE batches with `jq -s add`.

Output: JSON array of reconcile batch payloads. Each payload includes one target
page snapshot and every routed candidate targeting that same `(vault,page)`,
capped by --max-candidates for very large pages.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import OrderedDict
from datetime import date
from pathlib import Path
from typing import Any


def die(message: str) -> int:
    print(f"build-reconcile-batches: {message}", file=sys.stderr)
    return 1


def parse_positive_int(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if parsed < 1:
        raise ValueError(f"{name} must be >= 1")
    return parsed


def read_json_stdin() -> Any:
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise ValueError(f"routed input is not valid JSON: {exc}") from exc


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


def safe_target_path(root: Path, page: str) -> Path:
    page_path = Path(page)
    if page_path.is_absolute() or ".." in page_path.parts:
        raise ValueError(f"unsafe routed page path: {page}")
    target = (root / page_path).resolve()
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"routed page escapes vault root: {page}") from exc
    return target


def validate_routed_record(record: Any) -> tuple[str, dict[str, Any], dict[str, Any]] | None:
    if not isinstance(record, dict):
        raise ValueError("routed record is not an object")
    candidate_id = record.get("candidate_id")
    candidate = record.get("candidate")
    route = record.get("route")
    if not isinstance(candidate_id, str) or not candidate_id:
        raise ValueError("routed record missing candidate_id")
    if not isinstance(candidate, dict):
        raise ValueError(f"{candidate_id}: missing candidate object")
    if not isinstance(route, dict):
        raise ValueError(f"{candidate_id}: missing route object")
    status = route.get("status")
    if status != "routed":
        return None
    for key in ("vault", "page", "section"):
        if not isinstance(route.get(key), str) or not route[key].strip():
            raise ValueError(f"{candidate_id}: routed record missing route.{key}")
    return candidate_id, candidate, route


def chunked(items: list[dict[str, Any]], size: int) -> list[list[dict[str, Any]]]:
    return [items[start : start + size] for start in range(0, len(items), size)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build dream-skill RECONCILE batches.")
    parser.add_argument(
        "--config",
        default=os.environ.get("DREAM_CONFIG", str(Path.home() / ".claude/dream-skill/config.toml")),
        help="dream-skill config.toml path",
    )
    parser.add_argument(
        "--run-date",
        default=date.today().isoformat(),
        help="run date to pass to reconciliation agents",
    )
    parser.add_argument(
        "--max-candidates",
        default=os.environ.get("DREAM_RECONCILE_BATCH_SIZE", "25"),
        help="maximum candidates per reconcile agent batch (default: 25)",
    )
    args = parser.parse_args(argv)

    try:
        max_candidates = parse_positive_int(args.max_candidates, "--max-candidates")
        roots = parse_vault_roots(Path(args.config))
        routed_payload = read_json_stdin()
        if not isinstance(routed_payload, list):
            return die("input must be a JSON array of routed records")

        groups: "OrderedDict[tuple[str, str], list[dict[str, Any]]]" = OrderedDict()
        for record in routed_payload:
            validated = validate_routed_record(record)
            if validated is None:
                continue
            candidate_id, candidate, route = validated
            key = (route["vault"], route["page"])
            groups.setdefault(key, []).append(
                {
                    "candidate_id": candidate_id,
                    "candidate": candidate,
                    "route": {
                        "vault": route["vault"],
                        "page": route["page"],
                        "section": route["section"],
                        "routing_confidence": route.get("routing_confidence"),
                    },
                }
            )

        batches: list[dict[str, Any]] = []
        for key, candidates in groups.items():
            vault, page = key
            root = roots.get(vault)
            if root is None:
                raise ValueError(f"no vault root configured for routed vault: {vault}")
            target_path = safe_target_path(root, page)
            target_page = (
                target_path.read_text(encoding="utf-8", errors="ignore")
                if target_path.is_file()
                else ""
            )
            for candidate_chunk in chunked(candidates, max_candidates):
                batches.append(
                    {
                        "batch_id": f"reconcile-{len(batches) + 1:04d}",
                        "target": {"vault": vault, "page": page},
                        "target_page_path": str(target_path),
                        "target_page": target_page,
                        "run_date": args.run_date,
                        "candidates": candidate_chunk,
                    }
                )
    except ValueError as exc:
        return die(str(exc))

    json.dump(batches, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
