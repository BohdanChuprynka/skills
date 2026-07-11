#!/usr/bin/env python3
"""Collect content-free Dream run metrics from a run work directory."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TOKEN_RE = re.compile(r"^tokens used\s*\n\s*([0-9][0-9,]*)\s*$", re.MULTILINE)
MODEL_RE = re.compile(r"^model:\s*(.+?)\s*$", re.MULTILINE)
PROVIDER_RE = re.compile(r"^provider:\s*(.+?)\s*$", re.MULTILINE)
TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)", re.MULTILINE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--status",
        required=True,
        choices=("completed", "review-only", "dry-run", "failed"),
    )
    parser.add_argument("--source", default="all", choices=("claude", "codex", "all"))
    parser.add_argument("--window-start")
    parser.add_argument("--window-end")
    parser.add_argument("--chats-found", type=int)
    parser.add_argument("--chats-private-skipped", type=int)
    parser.add_argument("--chats-prefiltered", type=int)
    parser.add_argument("--started-at")
    parser.add_argument("--ended-at")
    parser.add_argument("--run-summary", type=Path)
    parser.add_argument("--review-input", type=Path)
    parser.add_argument("--review-decisions", type=Path)
    parser.add_argument("--review-decisions-before", type=Path)
    parser.add_argument(
        "--metrics-dir",
        type=Path,
        default=Path(os.environ.get("DREAM_METRICS_DIR", ""))
        if os.environ.get("DREAM_METRICS_DIR")
        else Path(os.environ.get("DREAM_HOME", str(Path.home() / ".claude/dream-skill")))
        / "metrics",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def load_json(path: Path | None, default: Any = None) -> Any:
    if path is None or not path.is_file():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def first_existing(workdir: Path, names: tuple[str, ...]) -> Path | None:
    for name in names:
        path = workdir / name
        if path.is_file():
            return path
    return None


def count_array_files(paths: list[Path]) -> tuple[int, int]:
    total = 0
    invalid = 0
    for path in paths:
        value = load_json(path)
        if isinstance(value, list):
            total += len(value)
        else:
            invalid += 1
    return total, invalid


def route_value(record: dict[str, Any], key: str) -> Any:
    route = record.get("route")
    if isinstance(route, dict) and key in route:
        return route.get(key)
    return record.get(key)


def decision_value(record: dict[str, Any], key: str) -> Any:
    decision = record.get("decision")
    if isinstance(decision, dict) and key in decision:
        return decision.get(key)
    return record.get(key)


def counter_dict(values: list[Any]) -> dict[str, int]:
    return dict(sorted(Counter(str(value) for value in values if value not in (None, "")).items()))


def active_stage_logs(workdir: Path, phase: str) -> list[Path]:
    """Return only logs belonging to batches in the current stage summary."""
    summary = load_json(workdir / f"{phase}-run-summary.json", {})
    results = summary.get("results") if isinstance(summary, dict) else None
    if not isinstance(results, list):
        return sorted(workdir.glob(f"{phase}-log-*.txt"))

    paths: list[Path] = []
    for result in results:
        if not isinstance(result, dict):
            continue
        batch_id = result.get("batch_id")
        attempts = result.get("attempts")
        if not isinstance(batch_id, str) or not batch_id:
            continue
        if isinstance(attempts, int) and attempts > 0:
            paths.extend(
                workdir / f"{phase}-log-{batch_id}-attempt-{attempt:02d}.txt"
                for attempt in range(1, attempts + 1)
            )
        elif result.get("status") == "skipped-existing":
            paths.extend(sorted(workdir.glob(f"{phase}-log-{batch_id}-attempt-*.txt")))
    return [path for path in dict.fromkeys(paths) if path.is_file()]


def collect_usage(workdir: Path) -> tuple[dict[str, Any], list[datetime]]:
    phases: dict[str, dict[str, Any]] = {}
    all_times: list[datetime] = []
    total_tokens = 0

    for phase in ("map", "route", "reconcile"):
        logs = active_stage_logs(workdir, phase)
        tokens = 0
        observed = 0
        models: Counter[str] = Counter()
        providers: Counter[str] = Counter()
        phase_times: list[datetime] = []

        for path in logs:
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            token_matches = TOKEN_RE.findall(text)
            if token_matches:
                tokens += int(token_matches[-1].replace(",", ""))
                observed += 1
            model = MODEL_RE.search(text)
            provider = PROVIDER_RE.search(text)
            if model:
                models[model.group(1).strip()] += 1
            if provider:
                providers[provider.group(1).strip()] += 1
            for raw in TIMESTAMP_RE.findall(text):
                try:
                    phase_times.append(datetime.fromisoformat(raw.replace("Z", "+00:00")))
                except ValueError:
                    pass

        phase_metric: dict[str, Any] = {
            "agents": len(logs),
            "agents_with_token_usage": observed,
            "tokens_observed": tokens,
            "models": dict(sorted(models.items())),
            "providers": dict(sorted(providers.items())),
        }
        if phase_times:
            phase_metric["wall_seconds_observed"] = round(
                (max(phase_times) - min(phase_times)).total_seconds(), 3
            )
            all_times.extend(phase_times)
        phases[phase] = phase_metric
        total_tokens += tokens

    phases["total_tokens_observed"] = total_tokens
    return phases, all_times


def collect_review(args: argparse.Namespace) -> dict[str, Any]:
    after = load_json(args.review_decisions, {})
    before = load_json(args.review_decisions_before, {})
    review_input = load_json(args.review_input, {})
    if not isinstance(after, dict):
        after = {}
    if not isinstance(before, dict):
        before = {}

    changed = {key: value for key, value in after.items() if before.get(key) != value}
    result: dict[str, Any] = {
        "decisions_this_run": len(changed),
        "outcomes": counter_dict(list(changed.values())),
    }

    entries = review_input.get("entries", []) if isinstance(review_input, dict) else []
    by_id = {
        str(entry.get("id")): entry
        for entry in entries
        if isinstance(entry, dict) and entry.get("id") is not None
    }
    by_confidence: dict[str, Counter[str]] = defaultdict(Counter)
    by_vault: dict[str, Counter[str]] = defaultdict(Counter)
    for candidate_id, outcome in changed.items():
        entry = by_id.get(str(candidate_id), {})
        confidence = str(entry.get("confidence") or "unknown")
        vault = str(entry.get("vault") or "unrouted")
        by_confidence[confidence][str(outcome)] += 1
        by_vault[vault][str(outcome)] += 1
    result["outcomes_by_confidence"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_confidence.items())
    }
    result["outcomes_by_vault"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_vault.items())
    }
    return result


def collect(args: argparse.Namespace) -> dict[str, Any]:
    workdir = args.workdir.resolve()
    if not workdir.is_dir():
        raise ValueError(f"workdir does not exist: {workdir}")

    map_units = load_json(workdir / "map-units.json", [])
    if not isinstance(map_units, list):
        map_units = []
    unit_kinds = counter_dict(
        [unit.get("kind") for unit in map_units if isinstance(unit, dict)]
    )

    map_validation = load_json(workdir / "map-validation-summary.json", {})
    map_valid_records: list[dict[str, Any]] = []
    if isinstance(map_validation, dict) and isinstance(map_validation.get("total_valid"), int):
        map_valid = map_validation["total_valid"]
        invalid_map = len(map_validation.get("invalid_units") or [])
    else:
        map_valid_path = first_existing(workdir, ("map-valid.json", "map-candidates.json"))
        map_valid_data = load_json(map_valid_path, None)
        if isinstance(map_valid_data, list):
            map_valid = len(map_valid_data)
            map_valid_records = [item for item in map_valid_data if isinstance(item, dict)]
            invalid_map = 0
        else:
            map_valid, invalid_map = count_array_files(sorted(workdir.glob("map-valid-map-*.json")))

    reduced_data = load_json(workdir / "reduced.json", [])
    reduced = len(reduced_data) if isinstance(reduced_data, list) else 0

    route_batches = load_json(workdir / "route-batches.json", [])
    route_batch_count = len(route_batches) if isinstance(route_batches, list) else 0
    route_path = first_existing(
        workdir,
        (
            "routed-records-canonical.json",
            "routed-records.json",
            "routed-records-review-only.json",
        ),
    )
    routed_records = load_json(route_path, [])
    if not isinstance(routed_records, list):
        routed_records = []
    route_status = counter_dict(
        [route_value(record, "status") for record in routed_records if isinstance(record, dict)]
    )
    route_confidence = counter_dict(
        [
            route_value(record, "routing_confidence")
            for record in routed_records
            if isinstance(record, dict)
        ]
    )
    vaults = counter_dict(
        [route_value(record, "vault") for record in routed_records if isinstance(record, dict)]
    )
    page_counts = Counter()
    for record in routed_records:
        if not isinstance(record, dict):
            continue
        vault = route_value(record, "vault")
        page = route_value(record, "page")
        if vault and page:
            page_counts[f"{vault}/{page}"] += 1
    route_validation = load_json(workdir / "route-validation-summary.json", {})
    invalid_route = (
        len(route_validation.get("invalid_batches") or [])
        if isinstance(route_validation, dict)
        else 0
    )

    reconcile_batches = load_json(workdir / "reconcile-batches.json", [])
    reconcile_batch_count = len(reconcile_batches) if isinstance(reconcile_batches, list) else 0
    reconcile_path = first_existing(
        workdir,
        ("reconcile-decisions-all.json", "reconcile-decisions.json"),
    )
    decisions = load_json(reconcile_path, [])
    if not isinstance(decisions, list):
        decisions = []
    reconcile_actions = counter_dict(
        [decision_value(record, "action") for record in decisions if isinstance(record, dict)]
    )
    needs_review = counter_dict(
        [decision_value(record, "needs_review") for record in decisions if isinstance(record, dict)]
    )

    run_summary_path = args.run_summary or first_existing(workdir, ("run-summary.json",))
    run_summary = load_json(run_summary_path, {})
    facts = run_summary.get("facts", []) if isinstance(run_summary, dict) else []
    if not isinstance(facts, list):
        facts = []
    apply_actions = counter_dict(
        [fact.get("action") for fact in facts if isinstance(fact, dict)]
    )
    apply_statuses = counter_dict(
        [fact.get("review_status") for fact in facts if isinstance(fact, dict)]
    )

    usage, observed_times = collect_usage(workdir)
    review_metrics = collect_review(args)
    started_at = args.started_at
    ended_at = args.ended_at
    if not started_at and observed_times:
        started_at = min(observed_times).isoformat().replace("+00:00", "Z")
    if not ended_at and observed_times:
        ended_at = max(observed_times).isoformat().replace("+00:00", "Z")

    duration_seconds = None
    if started_at and ended_at:
        try:
            start_dt = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
            end_dt = datetime.fromisoformat(ended_at.replace("Z", "+00:00"))
            duration_seconds = round((end_dt - start_dt).total_seconds(), 3)
        except ValueError:
            pass

    chats_found = args.chats_found
    if chats_found is None and isinstance(run_summary, dict):
        value = run_summary.get("chats_scanned")
        chats_found = value if isinstance(value, int) else None

    routed_count = route_status.get("routed", 0)
    gap_count = route_status.get("gap", 0) + route_status.get("ambiguous", 0)
    duplicate_count = reconcile_actions.get("duplicate", 0)

    derived: dict[str, float] = {}
    if chats_found:
        derived["map_candidates_per_chat"] = round(map_valid / chats_found, 4)
        derived["reduced_candidates_per_chat"] = round(reduced / chats_found, 4)
    if map_valid:
        derived["reduce_retention_rate"] = round(reduced / map_valid, 4)
    if routed_count + gap_count:
        derived["route_gap_rate"] = round(gap_count / (routed_count + gap_count), 4)
    if decisions:
        derived["reconcile_duplicate_rate"] = round(duplicate_count / len(decisions), 4)
    if map_valid and usage["map"]["tokens_observed"]:
        derived["map_tokens_per_candidate"] = round(
            usage["map"]["tokens_observed"] / map_valid, 2
        )
    if routed_records and usage["route"]["tokens_observed"]:
        derived["route_tokens_per_candidate"] = round(
            usage["route"]["tokens_observed"] / len(routed_records), 2
        )
    if decisions and usage["reconcile"]["tokens_observed"]:
        derived["reconcile_tokens_per_candidate"] = round(
            usage["reconcile"]["tokens_observed"] / len(decisions), 2
        )
    if chats_found and usage["total_tokens_observed"]:
        derived["observed_tokens_per_chat"] = round(
            usage["total_tokens_observed"] / chats_found, 2
        )
    review_outcomes = review_metrics["outcomes"]
    reviewed = sum(review_outcomes.values())
    if reviewed:
        derived["review_reject_rate"] = round(review_outcomes.get("reject", 0) / reviewed, 4)
        derived["review_defer_rate"] = round(review_outcomes.get("defer", 0) / reviewed, 4)

    metrics: dict[str, Any] = {
        "schema_version": 1,
        "run_id": args.run_id,
        "recorded_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "status": args.status,
        "source": args.source,
        "window": {"start": args.window_start, "end": args.window_end},
        "timing": {
            "started_at": started_at,
            "ended_at": ended_at,
            "duration_seconds": duration_seconds,
        },
        "counts": {
            "transcripts": {
                "found": chats_found,
                "private_skipped": args.chats_private_skipped,
                "prefiltered": args.chats_prefiltered,
            },
            "map": {
                "units": len(map_units),
                "unit_kinds": unit_kinds,
                "valid_candidates": map_valid,
                "invalid_units": invalid_map,
                "source_roles": counter_dict([item.get("source_role") for item in map_valid_records]),
                "confidence": counter_dict([item.get("confidence") for item in map_valid_records]),
                "types": counter_dict([item.get("type") for item in map_valid_records]),
            },
            "reduce": {
                "input_candidates": map_valid,
                "output_candidates": reduced,
                "removed_candidates": max(map_valid - reduced, 0),
                "confidence": counter_dict(
                    [item.get("confidence") for item in reduced_data if isinstance(item, dict)]
                ),
                "types": counter_dict(
                    [item.get("type") for item in reduced_data if isinstance(item, dict)]
                ),
            },
            "route": {
                "batches": route_batch_count,
                "records": len(routed_records),
                "status": route_status,
                "confidence": route_confidence,
                "target_vaults": vaults,
                "top_target_pages": dict(page_counts.most_common(20)),
                "invalid_batches": invalid_route,
            },
            "reconcile": {
                "batches": reconcile_batch_count,
                "decisions": len(decisions),
                "actions": reconcile_actions,
                "needs_review": needs_review,
            },
            "review": review_metrics,
            "apply": {
                "fact_events": len(facts),
                "actions": apply_actions,
                "review_status": apply_statuses,
            },
        },
        "usage": usage,
        "derived": derived,
    }
    return metrics


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def persist(metrics: dict[str, Any], metrics_dir: Path) -> None:
    metrics_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(metrics_dir, 0o700)
    snapshot = metrics_dir / "runs" / f"{metrics['run_id']}.json"
    write_atomic(snapshot, json.dumps(metrics, indent=2, sort_keys=True) + "\n")

    history = metrics_dir / "runs.jsonl"
    records: list[dict[str, Any]] = []
    if history.is_file():
        for line in history.read_text(encoding="utf-8").splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict) and record.get("run_id") != metrics["run_id"]:
                records.append(record)
    records.append(metrics)
    records.sort(
        key=lambda record: (
            str((record.get("window") or {}).get("end") or ""),
            str(record.get("recorded_at", "")),
            str(record.get("run_id", "")),
        )
    )
    write_atomic(history, "".join(json.dumps(record, sort_keys=True) + "\n" for record in records))


def main() -> int:
    args = parse_args()
    try:
        metrics = collect(args)
        rendered = json.dumps(metrics, indent=2, sort_keys=True) + "\n"
        if args.dry_run:
            sys.stdout.write(rendered)
        else:
            persist(metrics, args.metrics_dir.expanduser())
            sys.stdout.write(str(args.metrics_dir.expanduser() / "runs" / f"{args.run_id}.json") + "\n")
        return 0
    except (OSError, ValueError) as exc:
        print(f"collect-run-metrics: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
