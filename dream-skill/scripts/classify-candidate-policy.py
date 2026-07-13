#!/usr/bin/env python3
"""Attach a stable reporting class and conservative review policy to candidates.

MAP's free-form ``type`` remains useful diagnostic evidence, but it is too
fragmented to drive metrics or safety policy directly.  This helper preserves
that raw label, adds a bounded ``fact_class``, and marks obvious execution
telemetry for review instead of allowing a high-confidence auto-write.

The policy is intentionally lossless: candidates are never dropped here.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from typing import Any


FACT_CLASSES = {
    "identity",
    "preference",
    "relationship",
    "health",
    "fitness",
    "schedule",
    "goal",
    "learning",
    "project_decision",
    "project_constraint",
    "active_state",
    "audit_telemetry",
    "other",
}


def normalized(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "_", str(value or "").casefold()).strip("_")


def contains_any(value: str, words: tuple[str, ...]) -> bool:
    return any(word in value for word in words)


def fact_class(candidate: dict[str, Any]) -> str:
    raw_type = normalized(candidate.get("type"))
    content = str(candidate.get("content") or "").casefold()
    combined = f"{raw_type} {content}"

    rules: tuple[tuple[str, tuple[str, ...]], ...] = (
        ("relationship", ("relationship", "person", "people", "mentor", "contact", "networking")),
        ("health", ("health", "medical", "symptom", "acne", "skin", "medication", "condition")),
        ("fitness", ("fitness", "workout", "exercise", "running", "nutrition", "body_composition")),
        ("schedule", ("schedule", "calendar", "appointment", "meeting_time", "deadline")),
        ("preference", ("preference", "preferred", "communication_style", "workflow_preference", "tool_choice")),
        ("identity", ("identity", "bio", "background", "education", "credential", "experience", "skill", "role")),
        ("learning", ("learning", "study", "course", "exam_prep", "knowledge")),
        ("project_constraint", ("project_constraint", "architecture_constraint", "security_constraint", "product_constraint")),
        ("project_decision", ("project_decision", "architecture_decision", "product_decision", "technical_decision")),
        ("goal", ("goal", "priority", "aspiration", "career_direction", "objective")),
        ("audit_telemetry", ("test_receipt", "commit_hash", "file_churn", "debug_state", "git_state")),
        ("active_state", ("active_work", "project_status", "current_state", "blocker", "task_request", "next_action")),
    )
    for category, markers in rules:
        if contains_any(combined, markers):
            return category
    if candidate.get("memory_tier") == "current":
        return "active_state"
    return "other"


EXECUTION_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("pull_request_state", re.compile(r"\b(?:pr|pull request)\s*#?\d+\b|\bunmerged\b|\bmerge[- ]blocked\b", re.I)),
    ("branch_state", re.compile(r"\b(?:branch|worktree)\b.*\b(?:feat/|fix/|chore/|dedicated|isolated|current)\b|\b(?:feat|fix|chore)/[\w.-]+", re.I)),
    ("commit_state", re.compile(r"\bcommit\s+[0-9a-f]{7,40}\b|\b[0-9a-f]{7,40}\s+commit\b", re.I)),
    ("test_receipt", re.compile(r"\b(?:tests?|suite)\b.{0,48}\b(?:passed|failed|green|red|exit code|\d+\s*/\s*\d+)\b", re.I)),
    ("temporary_implementation", re.compile(r"\b(?:currently|actively)\s+(?:testing|implementing|debugging|building)\b|\blocal development server\b", re.I)),
    ("handoff_state", re.compile(r"\b(?:do not|no)\s+(?:push|merge|open (?:a )?pr)\b|\btask-by-task implementation\b", re.I)),
)


def policy_reasons(candidate: dict[str, Any], category: str) -> list[str]:
    content = str(candidate.get("content") or "")
    reasons = [name for name, pattern in EXECUTION_PATTERNS if pattern.search(content)]
    if category == "audit_telemetry" and "audit_telemetry" not in reasons:
        reasons.append("audit_telemetry")
    # Stable standing workflow preferences can mention worktrees or testing in
    # general without being one-run telemetry.  Only the explicit patterns
    # above gate stable facts; current-tier matches are always reviewed.
    if candidate.get("memory_tier") != "current" and category != "audit_telemetry":
        return reasons
    return reasons


def classify(candidates: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], Counter[str], int]:
    output: list[dict[str, Any]] = []
    counts: Counter[str] = Counter()
    gated = 0
    for candidate in candidates:
        enriched = dict(candidate)
        category = fact_class(candidate)
        if category not in FACT_CLASSES:  # defensive; fact_class is deterministic
            category = "other"
        enriched["fact_class"] = category
        reasons = policy_reasons(candidate, category)
        if reasons:
            enriched["policy_review_only"] = True
            enriched["policy_reasons"] = reasons
            gated += 1
        counts[category] += 1
        output.append(enriched)
    return output, counts, gated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args(argv)
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"classify-candidate-policy: invalid JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        print("classify-candidate-policy: input must be an array of objects", file=sys.stderr)
        return 1
    output, counts, gated = classify(payload)
    if args.report:
        classes = ",".join(f"{key}:{counts[key]}" for key in sorted(counts))
        print(
            f"classify-candidate-policy: in={len(payload)} review_only={gated} classes={classes}",
            file=sys.stderr,
        )
    json.dump(output, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
