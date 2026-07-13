#!/usr/bin/env python3
"""Build a content-free quality report from Dream review outcomes and reasons."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


RECOMMENDATIONS = {
    "not_durable": "MAP precision: strengthen transient-work and telemetry rejection.",
    "unsupported": "MAP factuality: tighten evidence entailment and source-role handling.",
    "duplicate": "REDUCE/RECONCILE: improve semantic duplicate detection.",
    "stale": "Historical policy: tighten current-state aging or dating behavior.",
    "wrong_target": "ROUTE: improve retrieval candidates or destination selection.",
    "bad_wording": "MAP normalization: improve atomic phrasing and scope.",
    "other": "Manual audit: inspect uncategorized rejection patterns.",
    "unspecified": "Review UX: collect a structured reason for remaining rejects.",
}


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def sorted_counter(counter: Counter[str]) -> dict[str, int]:
    return dict(sorted(counter.items()))


def dimension_key(value: object, fallback: str) -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


def summarized_groups(
    grouped_outcomes: dict[str, Counter[str]],
    grouped_reasons: dict[str, Counter[str]],
) -> dict[str, dict[str, Any]]:
    """Return content-free outcomes and rejection signals for one dimension."""
    result: dict[str, dict[str, Any]] = {}
    for key in sorted(set(grouped_outcomes) | set(grouped_reasons)):
        outcomes = grouped_outcomes[key]
        reasons = grouped_reasons[key]
        reviewed = sum(outcomes.values())
        rejected = outcomes.get("reject", 0)
        result[key] = {
            "reviewed": reviewed,
            "outcomes": sorted_counter(outcomes),
            "rejection_reasons": sorted_counter(reasons),
            "reject_rate": round(rejected / reviewed, 4) if reviewed else None,
        }
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review-input", type=Path, required=True)
    parser.add_argument("--decisions", type=Path, required=True)
    parser.add_argument("--feedback", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)

    review_input = load_json(args.review_input, {})
    decisions = load_json(args.decisions, {})
    feedback = load_json(args.feedback, {})
    if not isinstance(review_input, dict) or not isinstance(review_input.get("entries", []), list):
        print("summarize-review-feedback: invalid review input", file=sys.stderr)
        return 1
    if not isinstance(decisions, dict) or not isinstance(feedback, dict):
        print("summarize-review-feedback: decisions and feedback must be objects", file=sys.stderr)
        return 1

    entries = {
        str(item.get("id")): item
        for item in review_input.get("entries", [])
        if isinstance(item, dict) and item.get("id")
    }
    outcomes: Counter[str] = Counter()
    reasons: Counter[str] = Counter()
    by_vault: dict[str, Counter[str]] = defaultdict(Counter)
    by_type: dict[str, Counter[str]] = defaultdict(Counter)
    historical: Counter[str] = Counter()
    quality_sample: Counter[str] = Counter()
    by_run: dict[str, Counter[str]] = defaultdict(Counter)
    by_fact_class: dict[str, Counter[str]] = defaultdict(Counter)
    by_memory_tier: dict[str, Counter[str]] = defaultdict(Counter)
    by_sample: dict[str, Counter[str]] = defaultdict(Counter)
    by_historical: dict[str, Counter[str]] = defaultdict(Counter)
    grouped_outcomes: dict[str, dict[str, Counter[str]]] = {
        "fact_class": by_fact_class,
        "memory_tier": by_memory_tier,
        "quality_review_sample": by_sample,
        "historical_review": by_historical,
        "vault": by_vault,
        "run_id": by_run,
    }
    grouped_reasons: dict[str, dict[str, Counter[str]]] = {
        name: defaultdict(Counter) for name in grouped_outcomes
    }

    for candidate_id, decision in decisions.items():
        if candidate_id not in entries or decision not in {"approve", "reject", "defer"}:
            continue
        outcomes[str(decision)] += 1
        entry = entries[candidate_id]
        vault = str(entry.get("vault") or "unrouted")
        candidate_type = str(entry.get("candidate_type") or "unknown")
        run_id = str(entry.get("run_id") or "legacy-or-unknown")
        fact_class = dimension_key(entry.get("fact_class"), "unknown")
        memory_tier = dimension_key(entry.get("memory_tier"), "unknown")
        sample_key = "sample" if entry.get("quality_review_sample") else "not_sample"
        historical_key = "historical" if entry.get("historical_review") else "not_historical"
        by_vault[vault][str(decision)] += 1
        by_type[candidate_type][str(decision)] += 1
        by_run[run_id][str(decision)] += 1
        by_fact_class[fact_class][str(decision)] += 1
        by_memory_tier[memory_tier][str(decision)] += 1
        by_sample[sample_key][str(decision)] += 1
        by_historical[historical_key][str(decision)] += 1
        if entry.get("historical_review"):
            historical[str(decision)] += 1
        if entry.get("quality_review_sample"):
            quality_sample[str(decision)] += 1
        item_feedback = feedback.get(candidate_id)
        if isinstance(item_feedback, dict) and decision == "reject":
            reason = item_feedback.get("reason")
            if isinstance(reason, str) and reason:
                reasons[reason] += 1
                dimension_values = {
                    "fact_class": fact_class,
                    "memory_tier": memory_tier,
                    "quality_review_sample": sample_key,
                    "historical_review": historical_key,
                    "vault": vault,
                    "run_id": run_id,
                }
                for dimension, key in dimension_values.items():
                    grouped_reasons[dimension][key][reason] += 1

    reviewed = sum(outcomes.values())
    rejected = outcomes.get("reject", 0)
    report = {
        "schema_version": 2,
        "recorded_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "reviewed": reviewed,
        "outcomes": sorted_counter(outcomes),
        "rejection_reasons": sorted_counter(reasons),
        "outcomes_by_vault": {
            key: sorted_counter(value) for key, value in sorted(by_vault.items())
        },
        "outcomes_by_candidate_type": {
            key: sorted_counter(value) for key, value in sorted(by_type.items())
        },
        "outcomes_by_fact_class": {
            key: sorted_counter(value) for key, value in sorted(by_fact_class.items())
        },
        "outcomes_by_memory_tier": {
            key: sorted_counter(value) for key, value in sorted(by_memory_tier.items())
        },
        "outcomes_by_quality_review_sample": {
            key: sorted_counter(value) for key, value in sorted(by_sample.items())
        },
        "outcomes_by_historical_review": {
            key: sorted_counter(value) for key, value in sorted(by_historical.items())
        },
        "outcomes_by_run_id": {
            key: sorted_counter(value) for key, value in sorted(by_run.items())
        },
        "historical_review_outcomes": sorted_counter(historical),
        "quality_review_sample_outcomes": sorted_counter(quality_sample),
        "groups": {
            dimension: summarized_groups(
                grouped_outcomes[dimension], grouped_reasons[dimension]
            )
            for dimension in (
                "fact_class",
                "memory_tier",
                "quality_review_sample",
                "historical_review",
                "vault",
                "run_id",
            )
        },
        "derived": {
            "reject_rate": round(rejected / reviewed, 4) if reviewed else None,
            "reject_reason_coverage": round(sum(reasons.values()) / rejected, 4) if rejected else None,
            "quality_sample_reject_rate": (
                round(quality_sample.get("reject", 0) / sum(quality_sample.values()), 4)
                if quality_sample else None
            ),
        },
        "improvement_signals": [
            {"reason": reason, "count": count, "recommendation": RECOMMENDATIONS[reason]}
            for reason, count in reasons.most_common()
            if reason in RECOMMENDATIONS and count > 0
        ],
    }
    write_json(args.output, report)
    print(
        f"summarize-review-feedback: reviewed={reviewed} rejected={rejected} "
        f"reason_coverage={report['derived']['reject_reason_coverage']} -> {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
