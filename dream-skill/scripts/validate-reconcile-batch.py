#!/usr/bin/env python3
"""Validate one batched RECONCILE agent output.

Input:
  --batch <reconcile-batch.json>  The payload created by build-reconcile-batches.py.
  stdin                           The agent's JSON array output.

Accepted output item shape:
  {"candidate_id":"c000001", "decision": {...}}
or the decision fields directly with a sibling candidate_id:
  {"candidate_id":"c000001", "action":"new", ...}

Output:
  [{"candidate_id":"c000001","decision":{...}}]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ACTIONS = {"new", "duplicate", "supersede", "contradict"}
MODES = {"append", "replace", "stale", "none"}
CONFIDENCES = {"high", "medium", "low"}
REQUIRED_DECISION_KEYS = {
    "action",
    "mode",
    "target",
    "content",
    "candidate_confidence",
    "needs_review",
    "rationale",
}


def die(message: str) -> int:
    print(f"validate-reconcile-batch: {message}", file=sys.stderr)
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
        raise ValueError(f"reconcile output is not valid JSON: {exc}") from exc


def validate_batch(batch: Any) -> list[dict[str, Any]]:
    if not isinstance(batch, dict):
        raise ValueError("batch must be a JSON object")
    if "page_groups" in batch:
        groups = batch.get("page_groups")
        if not isinstance(groups, list) or not groups:
            raise ValueError("batch page_groups must be a non-empty array")
        grouped = [item for group in groups for item in validate_batch(group)]
        candidates = batch.get("candidates")
        if not isinstance(candidates, list):
            raise ValueError("packed batch missing flat candidates array")
        grouped_ids = [item.get("candidate_id") for item in grouped]
        flat_ids = [item.get("candidate_id") for item in candidates if isinstance(item, dict)]
        if grouped_ids != flat_ids:
            raise ValueError("packed batch candidates do not match page_groups")
        if len(set(grouped_ids)) != len(grouped_ids):
            raise ValueError("packed batch repeats a candidate across page_groups")
        return grouped
    target = batch.get("target")
    if not isinstance(target, dict):
        raise ValueError("batch missing target object")
    for key in ("vault", "page"):
        if not isinstance(target.get(key), str) or not target[key].strip():
            raise ValueError(f"batch target missing {key}")
    if not isinstance(batch.get("target_page"), str):
        raise ValueError("batch missing target_page string")
    if "allowed_old_lines" in batch and (
        not isinstance(batch["allowed_old_lines"], list)
        or not all(isinstance(line, str) for line in batch["allowed_old_lines"])
    ):
        raise ValueError("batch allowed_old_lines must be an array of strings")
    candidates = batch.get("candidates")
    if not isinstance(candidates, list):
        raise ValueError("batch missing candidates array")
    seen: set[str] = set()
    for item in candidates:
        if not isinstance(item, dict):
            raise ValueError("batch candidate item is not an object")
        candidate_id = item.get("candidate_id")
        candidate = item.get("candidate")
        if not isinstance(candidate_id, str) or not candidate_id:
            raise ValueError("batch candidate item missing candidate_id")
        if candidate_id in seen:
            raise ValueError(f"duplicate candidate_id in batch: {candidate_id}")
        if not isinstance(candidate, dict):
            raise ValueError(f"{candidate_id}: missing candidate object")
        route = item.get("route")
        if route is not None:
            if not isinstance(route, dict):
                raise ValueError(f"{candidate_id}: route must be an object")
            for key in ("vault", "page", "section"):
                if not isinstance(route.get(key), str) or not route[key].strip():
                    raise ValueError(f"{candidate_id}: route missing {key}")
            for key in ("vault", "page"):
                if route.get(key) != target.get(key):
                    raise ValueError(f"{candidate_id}: route.{key} does not match batch target")
        elif not isinstance(target.get("section"), str) or not target["section"].strip():
            raise ValueError(f"{candidate_id}: route missing and legacy batch target has no section")
        seen.add(candidate_id)
    return candidates


def normalize_decision(record: Any) -> tuple[str, dict[str, Any]]:
    if not isinstance(record, dict):
        raise ValueError("reconcile output item is not an object")
    candidate_id = record.get("candidate_id")
    if not isinstance(candidate_id, str) or not candidate_id:
        raise ValueError("reconcile output item missing candidate_id")
    if "decision" in record:
        decision = record["decision"]
        if not isinstance(decision, dict):
            raise ValueError(f"{candidate_id}: .decision is not an object")
        return candidate_id, dict(decision)
    decision = {key: value for key, value in record.items() if key != "candidate_id"}
    return candidate_id, decision


def validate_decision(
    candidate_id: str,
    decision: dict[str, Any],
    batch_target: dict[str, Any],
    candidate: dict[str, Any],
    expected_section: str,
    target_page: str,
    allowed_old_lines: list[str],
) -> None:
    missing = sorted(REQUIRED_DECISION_KEYS - set(decision))
    if missing:
        raise ValueError(f"{candidate_id}: decision missing required keys: {', '.join(missing)}")

    action = decision.get("action")
    mode = decision.get("mode")
    if action not in ACTIONS:
        raise ValueError(f"{candidate_id}: invalid action {action!r}")
    if mode not in MODES:
        raise ValueError(f"{candidate_id}: invalid mode {mode!r}")

    expected_mode = {
        "new": "append",
        "duplicate": "none",
        "supersede": "replace",
        "contradict": "replace",
    }[action]
    if mode != expected_mode:
        raise ValueError(f"{candidate_id}: action {action!r} requires mode {expected_mode!r}")

    if not isinstance(decision.get("target"), dict):
        raise ValueError(f"{candidate_id}: target must be an object")
    for key in ("vault", "page"):
        if decision["target"].get(key) != batch_target.get(key):
            raise ValueError(f"{candidate_id}: target.{key} does not match reconcile batch target")
    if decision["target"].get("section") != expected_section:
        raise ValueError(f"{candidate_id}: target.section does not match routed candidate section")

    confidence = decision.get("candidate_confidence")
    if confidence not in CONFIDENCES:
        raise ValueError(f"{candidate_id}: invalid candidate_confidence {confidence!r}")
    if confidence != candidate.get("confidence"):
        raise ValueError(f"{candidate_id}: candidate_confidence must copy candidate.confidence")

    if not isinstance(decision.get("needs_review"), bool):
        raise ValueError(f"{candidate_id}: needs_review must be boolean")
    expected_needs_review = not (
        action == "duplicate"
        or (action == "new" and confidence == "high")
    )
    if decision["needs_review"] != expected_needs_review:
        raise ValueError(
            f"{candidate_id}: needs_review must be {str(expected_needs_review).lower()} "
            f"for action={action}, confidence={confidence}"
        )

    if not isinstance(decision.get("rationale"), str) or not decision["rationale"].strip():
        raise ValueError(f"{candidate_id}: rationale must be a non-empty string")

    if action in {"supersede", "contradict"}:
        if not isinstance(decision.get("old_content"), str) or not decision["old_content"].strip():
            raise ValueError(f"{candidate_id}: {action} requires non-empty old_content")
    elif "old_content" in decision:
        raise ValueError(f"{candidate_id}: {action} must omit old_content")

    content = decision.get("content")
    if action == "duplicate":
        if content != "":
            raise ValueError(f"{candidate_id}: duplicate requires content to be an empty string")
    elif not isinstance(content, str) or not content.strip():
        raise ValueError(f"{candidate_id}: {action} requires non-empty content")

    if isinstance(content, str) and ("\n" in content or "\r" in content):
        raise ValueError(f"{candidate_id}: content must be exactly one line")

    if action == "new" and isinstance(content, str) and content.startswith("- "):
        raise ValueError(f"{candidate_id}: new content must not include a Markdown bullet prefix")

    if action in {"supersede", "contradict"}:
        old_content = decision["old_content"]
        if "\n" in old_content or "\r" in old_content:
            raise ValueError(f"{candidate_id}: old_content must be exactly one line")
        matches = allowed_old_lines.count(old_content)
        if matches != 1:
            raise ValueError(
                f"{candidate_id}: old_content must match exactly one complete line in the supplied page context; "
                f"found {matches}"
            )
        if old_content.startswith("#"):
            raise ValueError(f"{candidate_id}: destructive decisions may not replace headings")
        if old_content.startswith("- ") and not content.startswith("- "):
            raise ValueError(f"{candidate_id}: replacement must preserve Markdown bullet syntax")
        if old_content.startswith("|") and not (
            content.startswith("|") and content.rstrip().endswith("|")
        ):
            raise ValueError(f"{candidate_id}: replacement must preserve Markdown table-row syntax")


def canonicalize_decision(
    decision: dict[str, Any],
    batch_target: dict[str, Any],
    candidate: dict[str, Any],
    section: str,
) -> dict[str, Any]:
    """Derive mechanical fields locally; leave only semantic action/old-line choice to the model."""
    action = decision.get("action")
    if action not in ACTIONS:
        return decision
    normalized = dict(decision)
    normalized["mode"] = {
        "new": "append",
        "duplicate": "none",
        "supersede": "replace",
        "contradict": "replace",
    }[action]
    normalized["target"] = {
        "vault": batch_target.get("vault"),
        "page": batch_target.get("page"),
        "section": section,
    }
    confidence = candidate.get("confidence")
    normalized["candidate_confidence"] = confidence
    normalized["needs_review"] = not (
        action == "duplicate" or (action == "new" and confidence == "high")
    )
    # Provenance is immutable candidate data, not something the reconciliation
    # model may summarize or recreate. Carry the exact validated MAP source into
    # every decision so queued sidecars remain independently auditable after
    # successful-run work artifacts are cleaned.
    for key in ("source_chat", "source_event", "evidence"):
        if key in candidate:
            normalized[key] = candidate[key]
    candidate_content = candidate.get("content")
    if action == "duplicate":
        normalized["content"] = ""
        normalized.pop("old_content", None)
    elif action == "new":
        normalized["content"] = candidate_content
        normalized.pop("old_content", None)
    elif isinstance(candidate_content, str):
        old_content = normalized.get("old_content")
        if isinstance(old_content, str) and old_content.startswith("- "):
            normalized["content"] = "- " + candidate_content.removeprefix("- ")
        elif isinstance(old_content, str) and not old_content.startswith("|"):
            normalized["content"] = candidate_content
    return normalized


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate one dream-skill RECONCILE batch output.")
    parser.add_argument("--batch", required=True, help="reconcile batch JSON file")
    args = parser.parse_args(argv)

    try:
        batch = load_json_file(args.batch)
        inputs = validate_batch(batch)
        output = read_json_stdin()
        if isinstance(output, dict) and isinstance(output.get("decisions"), list):
            output = output["decisions"]
        if not isinstance(output, list):
            return die("reconcile output must be a JSON array, or an object with a decisions array")

        input_ids = [item["candidate_id"] for item in inputs]
        candidate_by_id = {item["candidate_id"]: item["candidate"] for item in inputs}
        section_by_id = {
            item["candidate_id"]: (
                item["route"]["section"]
                if isinstance(item.get("route"), dict)
                else batch["target"]["section"]
            )
            for item in inputs
        }
        context_by_id: dict[str, dict[str, Any]] = {}
        groups = batch.get("page_groups") if isinstance(batch.get("page_groups"), list) else [batch]
        for group in groups:
            for item in group["candidates"]:
                context_by_id[item["candidate_id"]] = group
        normalized = [normalize_decision(record) for record in output]
        decision_ids = [candidate_id for candidate_id, _ in normalized]
        duplicate_decision_ids = sorted(
            {candidate_id for candidate_id in decision_ids if decision_ids.count(candidate_id) > 1}
        )
        if duplicate_decision_ids:
            raise ValueError(f"duplicate candidate_id in reconcile output: {', '.join(duplicate_decision_ids)}")
        if sorted(input_ids) != sorted(decision_ids):
            missing = sorted(set(input_ids) - set(decision_ids))
            extra = sorted(set(decision_ids) - set(input_ids))
            detail = []
            if missing:
                detail.append("missing " + ", ".join(missing))
            if extra:
                detail.append("extra " + ", ".join(extra))
            raise ValueError("reconcile output candidate_id mismatch: " + "; ".join(detail))

        decision_by_id = dict(normalized)
        joined = []
        for candidate_id in input_ids:
            context = context_by_id[candidate_id]
            decision = canonicalize_decision(
                decision_by_id[candidate_id],
                context["target"],
                candidate_by_id[candidate_id],
                section_by_id[candidate_id],
            )
            validate_decision(
                candidate_id,
                decision,
                context["target"],
                candidate_by_id[candidate_id],
                section_by_id[candidate_id],
                context.get("target_page", ""),
                context.get(
                    "allowed_old_lines", context.get("target_page", "").splitlines()
                ),
            )
            joined.append({"candidate_id": candidate_id, "decision": decision})
    except ValueError as exc:
        return die(str(exc))

    json.dump(joined, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
