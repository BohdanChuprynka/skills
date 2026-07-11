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
import hashlib
import json
import os
import re
import sys
from collections import OrderedDict
from datetime import date
from pathlib import Path
from typing import Any


TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_+-]*", re.IGNORECASE)


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


def pack_page_batches(
    page_batches: list[dict[str, Any]],
    max_context_chars: int,
    max_pages: int,
    max_candidates: int,
    run_date: str,
) -> list[dict[str, Any]]:
    packs: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    current_chars = 0
    current_candidates = 0
    for page_batch in page_batches:
        context_chars = len(page_batch["target_page"])
        candidate_count = len(page_batch["candidates"])
        would_overflow = current and (
            len(current) >= max_pages
            or current_chars + context_chars > max_context_chars
            or current_candidates + candidate_count > max_candidates
        )
        if would_overflow:
            packs.append(current)
            current = []
            current_chars = 0
            current_candidates = 0
        current.append(page_batch)
        current_chars += context_chars
        current_candidates += candidate_count
    if current:
        packs.append(current)

    output: list[dict[str, Any]] = []
    for index, groups in enumerate(packs, 1):
        batch_id = f"reconcile-{index:04d}"
        if len(groups) == 1:
            single = dict(groups[0])
            single["batch_id"] = batch_id
            output.append(single)
            continue
        output.append(
            {
                "batch_id": batch_id,
                "target_page_scope": "multiple-isolated-page-contexts",
                "run_date": run_date,
                "page_groups": groups,
                "candidates": [candidate for group in groups for candidate in group["candidates"]],
            }
        )
    return output


def tokenize(text: str) -> set[str]:
    return {token.casefold() for token in TOKEN_RE.findall(text) if len(token) > 2}


def markdown_sections(text: str) -> tuple[list[str], dict[str, list[str]]]:
    lines = text.splitlines()
    preamble: list[str] = []
    sections: dict[str, list[str]] = OrderedDict()
    current: str | None = None
    for line in lines:
        if line.startswith("## "):
            current = line[3:].strip()
            sections[current] = [line]
        elif current is None:
            preamble.append(line)
        else:
            sections[current].append(line)
    return preamble, sections


def build_page_context(
    page_text: str,
    section_names: list[str],
    candidates: list[dict[str, Any]],
    max_chars: int,
) -> tuple[str, list[str], str]:
    preamble, sections = markdown_sections(page_text)
    query_terms: set[str] = set()
    for item in candidates:
        query_terms |= tokenize(str(item["candidate"].get("content") or ""))

    selected: list[str] = []
    for section_name in section_names:
        for line in sections.get(section_name, []):
            if line not in selected:
                selected.append(line)
    exact_lines: list[str] = list(selected)
    selected_set = set(selected)
    scored: list[tuple[int, int, str]] = []
    for index, line in enumerate(page_text.splitlines()):
        if not line.strip() or line in selected_set or line.startswith("#"):
            continue
        overlap = len(query_terms & tokenize(line))
        if overlap:
            scored.append((overlap, -index, line))
    scored.sort(reverse=True)
    matching_lines = [line for _, _, line in scored[:12]]
    exact_lines.extend(line for line in matching_lines if line not in selected_set)

    front = "\n".join(preamble[:80]).strip()
    outline = "\n".join(f"- {heading}" for heading in sections)
    selected_text = "\n".join(selected).strip()
    matches_text = "\n".join(matching_lines).strip()
    parts = [
        "<!-- bounded Dream reconciliation context; generated labels are not vault lines -->",
        front,
        "<!-- page H2 outline -->",
        outline,
        f"<!-- routed sections: {'; '.join(section_names)} -->",
        selected_text or "(section not present)",
        "<!-- lexical matches elsewhere in page -->",
        matches_text or "(none)",
    ]
    context = "\n".join(part for part in parts if part).strip()
    if len(context) > max_chars:
        # Keep exact lines intact. Prefer the routed section's beginning and end,
        # then matching lines; never slice through a Markdown line.
        budget_lines: list[str] = []
        used = 0
        candidates_lines = preamble[:20] + selected[:120] + matching_lines
        for line in candidates_lines:
            cost = len(line) + 1
            if used + cost > max_chars:
                break
            budget_lines.append(line)
            used += cost
        context = "\n".join(budget_lines)
        exact_lines = list(dict.fromkeys(budget_lines))
    return context, list(dict.fromkeys(exact_lines)), hashlib.sha256(page_text.encode("utf-8")).hexdigest()


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
        default=os.environ.get("DREAM_RECONCILE_BATCH_SIZE", "40"),
        help="maximum candidates per section-scoped reconcile agent batch (default: 40)",
    )
    parser.add_argument(
        "--max-context-chars",
        default=os.environ.get("DREAM_RECONCILE_CONTEXT_CHARS", "24000"),
        help="maximum page-context characters per reconcile batch (default: 24000)",
    )
    parser.add_argument(
        "--max-packed-context-chars",
        default=os.environ.get("DREAM_RECONCILE_PACKED_CONTEXT_CHARS", "32000"),
        help="maximum total context when packing several isolated pages (default: 32000)",
    )
    parser.add_argument(
        "--max-packed-pages",
        default=os.environ.get("DREAM_RECONCILE_PACKED_PAGES", "6"),
        help="maximum isolated page groups per agent batch (default: 6)",
    )
    args = parser.parse_args(argv)

    try:
        max_candidates = parse_positive_int(args.max_candidates, "--max-candidates")
        max_context_chars = parse_positive_int(args.max_context_chars, "--max-context-chars")
        max_packed_context_chars = parse_positive_int(
            args.max_packed_context_chars, "--max-packed-context-chars"
        )
        max_packed_pages = parse_positive_int(args.max_packed_pages, "--max-packed-pages")
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

        page_batches: list[dict[str, Any]] = []
        for key, candidates in groups.items():
            vault, page = key
            root = roots.get(vault)
            if root is None:
                raise ValueError(f"no vault root configured for routed vault: {vault}")
            target_path = safe_target_path(root, page)
            if not target_path.is_file():
                raise ValueError(f"routed page does not exist: {vault}/{page}")
            target_page = target_path.read_text(encoding="utf-8", errors="ignore")
            for candidate_chunk in chunked(candidates, max_candidates):
                section_names = list(
                    dict.fromkeys(item["route"]["section"] for item in candidate_chunk)
                )
                page_context, allowed_old_lines, page_sha256 = build_page_context(
                    target_page,
                    section_names,
                    candidate_chunk,
                    max_context_chars,
                )
                page_batches.append(
                    {
                        "target": {"vault": vault, "page": page},
                        "target_page_path": str(target_path),
                        "target_page": page_context,
                        "target_page_scope": "routed-section-plus-lexical-matches",
                        "target_page_sha256": page_sha256,
                        "allowed_old_lines": allowed_old_lines,
                        "run_date": args.run_date,
                        "candidates": candidate_chunk,
                    }
                )
        batches = pack_page_batches(
            page_batches,
            max_packed_context_chars,
            max_packed_pages,
            max_candidates,
            args.run_date,
        )
    except ValueError as exc:
        return die(str(exc))

    json.dump(batches, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
