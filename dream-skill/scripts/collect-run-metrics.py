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

from candidate_identity import candidate_id


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
    """Return every recorded attempt log without accepting unrelated files."""
    ledger = workdir / f"{phase}-attempt-ledger.jsonl"
    ledger_paths: list[Path] = []
    if ledger.is_file():
        for raw in ledger.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            for result in entry.get("results", []) if isinstance(entry, dict) else []:
                if not isinstance(result, dict):
                    continue
                for name in result.get("attempt_logs", []) or []:
                    if isinstance(name, str) and Path(name).name == name:
                        ledger_paths.append(workdir / name)
        return [path for path in dict.fromkeys(ledger_paths) if path.is_file()]

    # Backward-compatible fallback for workdirs created before the ledger.
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


def source_kind(path: str) -> str:
    normalized = path.replace("\\", "/")
    if "/.codex/sessions/" in normalized:
        return "codex"
    if "/.claude/projects/" in normalized:
        return "claude"
    return "other"


def collect_map_unit_metrics(workdir: Path, units: list[dict[str, Any]]) -> dict[str, Any]:
    by_kind: dict[str, Counter[str]] = defaultdict(Counter)
    per_source_units: Counter[str] = Counter()
    source_kinds: Counter[str] = Counter()
    zero_yield = 0
    for unit in units:
        if not isinstance(unit, dict):
            continue
        kind = str(unit.get("kind") or "unknown")
        unit_path = Path(str(unit.get("unit_path") or ""))
        try:
            input_bytes = unit_path.stat().st_size
        except OSError:
            input_bytes = 0
        output = load_json(workdir / f"map-out-{unit.get('batch_id')}.json", [])
        candidate_count = len(output) if isinstance(output, list) else 0
        if candidate_count == 0:
            zero_yield += 1
        by_kind[kind]["units"] += 1
        by_kind[kind]["input_bytes"] += input_bytes
        by_kind[kind]["candidates"] += candidate_count
        by_kind[kind]["zero_yield_units"] += int(candidate_count == 0)
        members = unit.get("members") if isinstance(unit.get("members"), list) else []
        sources = (
            [str(unit.get("source_chat"))]
            if unit.get("source_chat")
            else [str(item.get("source_chat")) for item in members if isinstance(item, dict) and item.get("source_chat")]
        )
        for source in sources:
            per_source_units[source] += 1
            source_kinds[source_kind(source)] += 1
    return {
        "by_kind": {key: dict(value) for key, value in sorted(by_kind.items())},
        "zero_yield_units": zero_yield,
        "max_units_per_source_chat": max(per_source_units.values(), default=0),
        "source_chat_counts": dict(sorted(source_kinds.items())),
    }


def collect_prefilter_metrics(workdir: Path) -> dict[str, Any]:
    manifest = load_json(workdir / "map-manifest.json", [])
    if not isinstance(manifest, list):
        return {}
    totals: Counter[str] = Counter()
    by_source: dict[str, Counter[str]] = defaultdict(Counter)
    for item in manifest:
        if not isinstance(item, dict):
            continue
        kind = source_kind(str(item.get("raw") or ""))
        for key in (
            "raw_bytes",
            "output_bytes",
            "raw_lines",
            "parsed_events",
            "emitted_lines",
            "skipped_events",
            "malformed_lines",
        ):
            value = item.get(key)
            if isinstance(value, int):
                totals[key] += value
                by_source[kind][key] += value
        totals["transcripts"] += 1
        by_source[kind]["transcripts"] += 1
    result: dict[str, Any] = {
        "totals": dict(totals),
        "by_source": {key: dict(value) for key, value in sorted(by_source.items())},
    }
    if totals.get("raw_bytes"):
        result["output_to_raw_byte_ratio"] = round(
            totals.get("output_bytes", 0) / totals["raw_bytes"], 4
        )
    return result


def collect_usage(workdir: Path) -> tuple[dict[str, Any], list[datetime]]:
    phases: dict[str, dict[str, Any]] = {}
    all_times: list[datetime] = []
    total_tokens = 0

    for phase in ("map", "route", "reconcile"):
        logs = active_stage_logs(workdir, phase)
        if phase == "route" and (workdir / "route-fallback").is_dir():
            logs.extend(active_stage_logs(workdir / "route-fallback", phase))
            logs = list(dict.fromkeys(logs))
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
    by_fact_class: dict[str, Counter[str]] = defaultdict(Counter)
    by_memory_tier: dict[str, Counter[str]] = defaultdict(Counter)
    by_review_cohort: dict[str, Counter[str]] = defaultdict(Counter)
    for candidate_id, outcome in changed.items():
        entry = by_id.get(str(candidate_id), {})
        confidence = str(entry.get("confidence") or "unknown")
        vault = str(entry.get("vault") or "unrouted")
        fact_class = str(entry.get("fact_class") or "other")
        memory_tier = str(entry.get("memory_tier") or "unknown")
        cohort = (
            "quality_sample"
            if entry.get("quality_review_sample") is True
            else "historical"
            if entry.get("historical_review") is True
            else "standard"
        )
        by_confidence[confidence][str(outcome)] += 1
        by_vault[vault][str(outcome)] += 1
        by_fact_class[fact_class][str(outcome)] += 1
        by_memory_tier[memory_tier][str(outcome)] += 1
        by_review_cohort[cohort][str(outcome)] += 1
    result["outcomes_by_confidence"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_confidence.items())
    }
    result["outcomes_by_vault"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_vault.items())
    }
    result["outcomes_by_fact_class"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_fact_class.items())
    }
    result["outcomes_by_memory_tier"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_memory_tier.items())
    }
    result["outcomes_by_review_cohort"] = {
        key: dict(sorted(value.items())) for key, value in sorted(by_review_cohort.items())
    }
    return result


def gate_dispositions(
    routable: list[dict[str, Any]],
    routed_records: list[dict[str, Any]],
    decisions: list[dict[str, Any]],
    people: list[dict[str, Any]],
) -> dict[str, Any]:
    routes = {
        str(record.get("candidate_id")): route_value(record, "status")
        for record in routed_records
        if isinstance(record, dict) and record.get("candidate_id")
    }
    decision_map = {
        str(record.get("candidate_id")): record.get("decision") or record
        for record in decisions
        if isinstance(record, dict) and record.get("candidate_id")
    }
    people_ids = {
        str(record.get("candidate_id"))
        for record in people
        if isinstance(record, dict) and record.get("candidate_id")
    }

    def disposition(cid: str) -> str:
        if cid in people_ids:
            return "people_review"
        status = routes.get(cid)
        if status in {"gap", "ambiguous"}:
            return str(status)
        decision = decision_map.get(cid)
        if not isinstance(decision, dict):
            return "unresolved"
        action = str(decision.get("action") or "unknown")
        if action == "duplicate":
            return "duplicate"
        if decision.get("needs_review") is True or action in {"supersede", "contradict"}:
            return "queued"
        if action == "new":
            return "written"
        return action

    cohorts: dict[str, Counter[str]] = defaultdict(Counter)
    for candidate in routable:
        if not isinstance(candidate, dict):
            continue
        cid = candidate_id(candidate)
        selected: list[str] = []
        if candidate.get("historical_review") is True:
            selected.append("historical")
        if candidate.get("quality_review_sample") is True:
            selected.append("quality_sample")
        if candidate.get("policy_review_only") is True:
            selected.append("policy_review")
        for cohort in selected:
            cohorts[cohort][disposition(cid)] += 1
    return {
        key: {"selected": sum(value.values()), "dispositions": dict(sorted(value.items()))}
        for key, value in sorted(cohorts.items())
    }


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
    map_valid_path = first_existing(workdir, ("map-valid.json", "map-candidates.json"))
    map_valid_data = load_json(map_valid_path, None)
    map_valid_records: list[dict[str, Any]] = (
        [item for item in map_valid_data if isinstance(item, dict)]
        if isinstance(map_valid_data, list)
        else []
    )
    if isinstance(map_validation, dict) and isinstance(map_validation.get("total_valid"), int):
        map_valid = map_validation["total_valid"]
        invalid_map = len(map_validation.get("invalid_units") or [])
    else:
        if isinstance(map_valid_data, list):
            map_valid = len(map_valid_data)
            map_valid_records = [item for item in map_valid_data if isinstance(item, dict)]
            invalid_map = 0
        else:
            map_valid, invalid_map = count_array_files(sorted(workdir.glob("map-valid-map-*.json")))

    reduced_data = load_json(workdir / "reduced.json", [])
    reduced = len(reduced_data) if isinstance(reduced_data, list) else 0
    routable_data = load_json(workdir / "routable.json", [])
    if not isinstance(routable_data, list):
        routable_data = []
    people_data = load_json(workdir / "people-review-queue.json", [])
    if not isinstance(people_data, list):
        people_data = []

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
        (
            "reconcile-decisions-enforced.json",
            "reconcile-decisions-gated.json",
            "reconcile-decisions-all.json",
            "reconcile-decisions.json",
        ),
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
    map_unit_metrics = collect_map_unit_metrics(workdir, map_units)
    prefilter_metrics = collect_prefilter_metrics(workdir)
    gate_metrics = gate_dispositions(routable_data, routed_records, decisions, people_data)
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
                "fact_classes": counter_dict([item.get("fact_class") for item in map_valid_records]),
                "units_detail": map_unit_metrics,
                "prefilter": prefilter_metrics,
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
                "routable_memory_tiers": counter_dict(
                    [item.get("memory_tier") for item in routable_data if isinstance(item, dict)]
                ),
                "routable_fact_classes": counter_dict(
                    [item.get("fact_class") for item in routable_data if isinstance(item, dict)]
                ),
                "gate_dispositions": gate_metrics,
                "people_review": len(people_data),
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
                "target_vaults": counter_dict(
                    [
                        str(fact.get("target") or "").split("/", 1)[0]
                        for fact in facts
                        if isinstance(fact, dict) and "/" in str(fact.get("target") or "")
                    ]
                ),
                "target_pages": counter_dict(
                    [fact.get("target") for fact in facts if isinstance(fact, dict)]
                ),
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
