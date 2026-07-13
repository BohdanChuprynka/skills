#!/usr/bin/env python3
"""Executable Codex Dream pipeline with retries, durable staging, and marker gating."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from vault_search import load_vault_config, load_vault_policies


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent

ENGINES = ("codex", "claude")
STAGE_MODEL_DEFAULTS = {
    "codex": {"map": "gpt-5.6-luna", "route": "gpt-5.6-luna", "reconcile": "gpt-5.6-luna"},
    "claude": {
        "map": "claude-haiku-4-5-20251001",
        "route": "claude-haiku-4-5-20251001",
        "reconcile": "claude-haiku-4-5-20251001",
    },
}
STAGE_EFFORT_DEFAULTS = {
    "codex": {"map": "medium", "route": "low", "reconcile": "medium"},
    "claude": {"map": None, "route": None, "reconcile": None},
}


class RunFailure(RuntimeError):
    pass


def resolve_stage_agent_defaults(args: argparse.Namespace) -> None:
    """CLI flag > DREAM_* env var > engine-keyed default, per stage."""
    for stage in ("map", "route", "reconcile"):
        for kind, table, env_suffix in (
            ("model", STAGE_MODEL_DEFAULTS, "MODEL"),
            ("effort", STAGE_EFFORT_DEFAULTS, "EFFORT"),
        ):
            attr = f"{stage}_{kind}"
            if getattr(args, attr) is None:
                env_value = os.environ.get(f"DREAM_{stage.upper()}_{env_suffix}")
                setattr(args, attr, env_value if env_value is not None else table[args.engine][stage])


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def append_jsonl(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False) + "\n")
    os.chmod(path, 0o600)


def run(
    command: list[str],
    *,
    stdin: str | None = None,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise RunFailure(f"{' '.join(command[:2])}: {detail[:1000]}")
    return result


def parse_batches(output: str) -> list[tuple[str, str, int, int, list[Path]]]:
    batches: list[tuple[str, str, int, int, list[Path]]] = []
    start = end = None
    start_epoch = end_epoch = None
    paths: list[Path] = []
    for line in output.splitlines():
        if line.startswith("BATCH:"):
            if None not in (start, end, start_epoch, end_epoch):
                batches.append((start, end, int(start_epoch), int(end_epoch), paths))
            parts = line.split(":")
            if len(parts) != 5:
                raise RunFailure("find-chats emitted a BATCH header without epoch boundaries")
            _, start, end, raw_start_epoch, raw_end_epoch = parts
            start_epoch, end_epoch = int(raw_start_epoch), int(raw_end_epoch)
            paths = []
        elif line.strip():
            if start is None:
                raise RunFailure("find-chats emitted a path before a BATCH header")
            paths.append(Path(line.strip()))
    if None not in (start, end, start_epoch, end_epoch):
        batches.append((start, end, int(start_epoch), int(end_epoch), paths))
    return batches


def parse_prefilter_stats(stderr: str) -> dict[str, int]:
    for line in stderr.splitlines():
        if not line.startswith("prefilter_stats "):
            continue
        parsed: dict[str, int] = {}
        for field in line.split()[1:]:
            key, separator, raw = field.partition("=")
            if separator and raw.isdigit():
                parsed[key] = int(raw)
        return parsed
    return {}


def stage_update(state: dict[str, Any], path: Path, stage: str, **values: Any) -> None:
    state.setdefault("stages", {})[stage] = {"updated_at": utc_now(), **values}
    state["updated_at"] = utc_now()
    atomic_json(path, state)


def stage_validation_failed(state: dict[str, Any], path: Path, stage: str) -> None:
    """Preserve stage counts while replacing status without duplicate kwargs."""
    previous = state.get("stages", {}).get(stage, {})
    carried = {
        key: value
        for key, value in previous.items()
        if key not in {"updated_at", "status"}
    }
    stage_update(
        state,
        path,
        stage,
        status="failed",
        **carried,
        validation_failed=True,
    )


def validate_environment(args: argparse.Namespace) -> None:
    if sys.version_info < (3, 11):
        raise RunFailure("Python 3.11 or newer is required")
    if args.dry_run and args.shadow:
        raise RunFailure("--dry-run and --shadow are mutually exclusive")
    if not args.config.is_file():
        raise RunFailure(f"config not found: {args.config}")
    if not args.cwd.is_dir():
        raise RunFailure(f"working directory not found: {args.cwd}")
    try:
        vaults = load_vault_config(args.config)
    except (OSError, ValueError) as exc:
        raise RunFailure(f"invalid config: {exc}") from exc
    if not vaults:
        raise RunFailure("config contains no usable [vaults.*] entries")
    missing_roots = [f"{name}={root}" for name, (root, _) in vaults.items() if not root.is_dir()]
    if missing_roots:
        raise RunFailure("configured vault roots not found: " + ", ".join(missing_roots))
    if shutil.which("jq") is None:
        raise RunFailure("jq is required")
    if args.engine == "codex":
        codex_path = Path(args.codex_bin).expanduser()
        if "/" in args.codex_bin:
            if not codex_path.is_file() or not os.access(codex_path, os.X_OK):
                raise RunFailure(f"Codex executable not found or not executable: {codex_path}")
        elif shutil.which(args.codex_bin) is None:
            raise RunFailure(f"Codex executable not found on PATH: {args.codex_bin}")
    else:
        claude_path = Path(args.claude_bin).expanduser()
        if "/" in args.claude_bin:
            if not claude_path.is_file() or not os.access(claude_path, os.X_OK):
                raise RunFailure(f"Claude executable not found or not executable: {claude_path}")
        elif shutil.which(args.claude_bin) is None:
            raise RunFailure(f"Claude executable not found on PATH: {args.claude_bin}")
    required = [
        "advance-marker.sh",
        "apply-decision.sh",
        "build-map-batches.py",
        "build-reconcile-batches.py",
        "build-route-batches.py",
        "classify-candidate-policy.py",
        "collect-run-metrics.py",
        "find-chats.sh",
        "gate-write-density.py",
        "gate-cross-target-conflicts.py",
        "prefilter-transcript.py",
        "reduce-dedup.py",
        "route-entities.py",
        "run-agent-batches.py",
        "validate-candidates.sh",
        "validate-reconcile-batch.py",
        "validate-route-batch.py",
        "write-receipt.sh",
    ]
    missing = [name for name in required if not os.access(SCRIPT_DIR / name, os.X_OK)]
    if missing:
        raise RunFailure("required helpers are missing or not executable: " + ", ".join(missing))
    for prompt in ("map.md", "route.md", "reconcile.md"):
        if not (SKILL_DIR / "prompts" / prompt).is_file():
            raise RunFailure(f"stage prompt missing: prompts/{prompt}")


def agent_stage(
    stage: str,
    workdir: Path,
    prompt: Path,
    args: argparse.Namespace,
    state: dict[str, Any],
    state_path: Path,
) -> None:
    command = [
        str(SCRIPT_DIR / "run-agent-batches.py"),
        "--stage",
        stage,
        "--workdir",
        str(workdir),
        "--instructions",
        str(prompt),
        "--cwd",
        str(args.cwd),
        "--engine",
        args.engine,
        "--codex-bin",
        args.codex_bin,
        "--claude-bin",
        args.claude_bin,
        "--concurrency",
        str(getattr(args, f"{stage}_concurrency")),
        "--timeout",
        str(getattr(args, f"{stage}_timeout")),
        "--retries",
        str(args.agent_retries),
    ]
    model = getattr(args, f"{stage}_model")
    effort = getattr(args, f"{stage}_effort")
    if model:
        command.extend(["--model", model])
    if effort:
        command.extend(["--effort", effort])
    if stage == "route":
        command.extend(["--routing-rules", str(SKILL_DIR / "ROUTING.md")])
    if stage in {"route", "reconcile"}:
        command.extend(["--config", str(args.config)])
    result = run(command, check=False)
    summary_path = workdir / f"{stage}-run-summary.json"
    summary = json.loads(summary_path.read_text()) if summary_path.is_file() else {}
    results = summary.get("results") if isinstance(summary, dict) else []
    if not isinstance(results, list):
        results = []
    semantic_failures = [
        item
        for item in results if isinstance(item, dict)
        and item.get("status") == "semantic-validation-failed"
    ]
    stage_update(
        state,
        state_path,
        stage,
        status="success" if result.returncode == 0 else "failed",
        total=summary.get("tasks"),
        completed=summary.get("completed"),
        failed=summary.get("failed"),
        prompt_sha256=summary.get("prompt_sha256"),
        **({"validation_failed": True} if semantic_failures else {}),
    )
    if result.returncode != 0:
        detail = next(
            (
                str(item.get("validation_error"))
                for item in semantic_failures
                if item.get("validation_error")
            ),
            "",
        )
        suffix = f": {detail}" if detail else f"; see {summary_path}"
        raise RunFailure(f"{stage} agents left unresolved batches{suffix}")


def validate_map(workdir: Path) -> list[dict[str, Any]]:
    units = json.loads((workdir / "map-units.json").read_text())
    valid_all: list[dict[str, Any]] = []
    for unit in units:
        batch_id = unit["batch_id"]
        output_path = workdir / f"map-out-{batch_id}.json"
        command = [str(SCRIPT_DIR / "validate-candidates.sh"), "--unit", unit["unit_path"]]
        if unit["kind"] == "chunk":
            command.extend(["--source-chat", unit["source_chat"]])
        result = run(command, stdin=output_path.read_text())
        candidates = json.loads(result.stdout)
        if unit["kind"] == "chunk":
            for candidate in candidates:
                candidate["source_chat"] = unit["source_chat"]
                candidate["source_date"] = unit["source_date"]
        else:
            members = {member["source_chat"]: member["source_date"] for member in unit["members"]}
            candidates = [candidate for candidate in candidates if candidate.get("source_chat") in members]
            for candidate in candidates:
                candidate["source_date"] = members[candidate["source_chat"]]
        valid_all.extend(candidates)
    atomic_json(workdir / "map-valid.json", valid_all)
    return valid_all


def combine_route(workdir: Path, config: Path) -> list[dict[str, Any]]:
    batches = json.loads((workdir / "route-batches.json").read_text())
    records: list[dict[str, Any]] = []
    for batch in batches:
        batch_id = batch["batch_id"]
        result = run(
            [
                str(SCRIPT_DIR / "validate-route-batch.py"),
                "--batch",
                str(workdir / f"{batch_id}.json"),
                "--config",
                str(config),
                "--missing-page-policy",
                "gap",
            ],
            stdin=(workdir / f"route-out-{batch_id}.json").read_text(),
        )
        records.extend(json.loads(result.stdout))
    atomic_json(workdir / "routed-records.json", records)
    return records


def build_route_fallback_batches(
    workdir: Path,
    records: list[dict[str, Any]],
) -> tuple[Path, int]:
    """Create a second-pass ROUTE workdir containing only unresolved facts."""
    unresolved = {
        str(record.get("candidate_id"))
        for record in records
        if isinstance(record, dict) and route_status(record) in {"gap", "ambiguous"}
    }
    fallback_dir = workdir / "route-fallback"
    fallback_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(fallback_dir, 0o700)
    if not unresolved:
        atomic_json(fallback_dir / "route-batches.json", [])
        return fallback_dir, 0

    original = load_json(workdir / "route-batches.json")
    batches: list[dict[str, Any]] = []
    for batch in original if isinstance(original, list) else []:
        candidates = [
            item
            for item in batch.get("candidates", [])
            if isinstance(item, dict) and str(item.get("candidate_id")) in unresolved
        ]
        if not candidates:
            continue
        batches.append(
            {
                "batch_id": f"route-fallback-{len(batches) + 1:04d}",
                "candidates": candidates,
                "page_catalog": batch.get("page_catalog", []),
            }
        )
    atomic_json(fallback_dir / "route-batches.json", batches)
    return fallback_dir, len(unresolved)


def route_status(record: dict[str, Any]) -> str:
    route = record.get("route") if isinstance(record, dict) else None
    return str(route.get("status") or "") if isinstance(route, dict) else ""


def run_route_fallback(
    args: argparse.Namespace,
    workdir: Path,
    records: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    fallback_dir, unresolved_count = build_route_fallback_batches(workdir, records)
    if not args.route_gap_retry or unresolved_count == 0:
        return records, {"attempted": 0, "recovered": 0, "remaining": unresolved_count}

    command = [
        str(SCRIPT_DIR / "run-agent-batches.py"),
        "--stage",
        "route",
        "--workdir",
        str(fallback_dir),
        "--instructions",
        str(SKILL_DIR / "prompts/route.md"),
        "--routing-rules",
        str(SKILL_DIR / "ROUTING.md"),
        "--cwd",
        str(args.cwd),
        "--engine",
        args.engine,
        "--codex-bin",
        args.codex_bin,
        "--claude-bin",
        args.claude_bin,
        "--concurrency",
        str(min(args.route_concurrency, 2)),
        "--timeout",
        str(args.route_timeout),
        "--retries",
        str(args.agent_retries),
        "--config",
        str(args.config),
    ]
    if args.route_model:
        command.extend(["--model", args.route_model])
    if args.route_fallback_effort:
        command.extend(["--effort", args.route_fallback_effort])
    run(command)
    fallback_records = combine_route(fallback_dir, args.config)
    fallback_by_id = {
        str(record.get("candidate_id")): record
        for record in fallback_records
        if isinstance(record, dict) and record.get("candidate_id")
    }
    merged: list[dict[str, Any]] = []
    recovered = 0
    for original in records:
        cid = str(original.get("candidate_id") or "")
        replacement = fallback_by_id.get(cid)
        if replacement is None:
            merged.append(original)
            continue
        enriched = dict(replacement)
        enriched["route_attempts"] = 2
        enriched["initial_route_status"] = route_status(original)
        if route_status(original) != "routed" and route_status(replacement) == "routed":
            recovered += 1
        merged.append(enriched)
    remaining = sum(route_status(record) != "routed" for record in merged)
    return merged, {"attempted": unresolved_count, "recovered": recovered, "remaining": remaining}


def combine_reconcile(workdir: Path) -> list[dict[str, Any]]:
    batches = json.loads((workdir / "reconcile-batches.json").read_text())
    decisions: list[dict[str, Any]] = []
    for batch in batches:
        batch_id = batch["batch_id"]
        result = run(
            [
                str(SCRIPT_DIR / "validate-reconcile-batch.py"),
                "--batch",
                str(workdir / f"{batch_id}.json"),
            ],
            stdin=(workdir / f"reconcile-out-{batch_id}.json").read_text(),
        )
        decisions.extend(json.loads(result.stdout))
    atomic_json(workdir / "reconcile-decisions.json", decisions)
    return decisions


def persist_routing_gaps(home: Path, run_id: str, workdir: Path, records: list[dict[str, Any]]) -> None:
    batches = load_json(workdir / "route-batches.json")
    retrieval: dict[str, list[dict[str, Any]]] = {}
    for batch in batches if isinstance(batches, list) else []:
        catalog = {
            item.get("page_id"): item
            for item in batch.get("page_catalog", [])
            if isinstance(item, dict)
        }
        for item in batch.get("candidates", []):
            if not isinstance(item, dict) or not item.get("candidate_id"):
                continue
            retrieval[str(item["candidate_id"])] = [
                {
                    "vault": str(catalog[page_id].get("vault")),
                    "page": str(catalog[page_id].get("page")),
                    "retrieval_score": catalog[page_id].get("retrieval_score"),
                }
                for page_id in item.get("allowed_page_ids", [])
                if page_id in catalog
            ]
    gaps = []
    for record in records:
        route = record.get("route") if isinstance(record, dict) else None
        if not isinstance(route, dict) or route.get("status") == "routed":
            continue
        candidate = record.get("candidate") if isinstance(record.get("candidate"), dict) else {}
        candidate_id = str(record.get("candidate_id") or "")
        gaps.append(
            {
                "candidate_id": candidate_id,
                "status": route.get("status"),
                "reason": (
                    "ambiguous_pages"
                    if route.get("status") == "ambiguous"
                    else "no_suitable_page"
                    if retrieval.get(candidate_id)
                    else "no_candidates"
                ),
                "content": candidate.get("content"),
                "type": candidate.get("type"),
                "suggested_section": candidate.get("suggested_section"),
                "source_date": candidate.get("source_date"),
                "retrieved_pages": retrieval.get(candidate_id, []),
            }
        )
    atomic_json(home / "gaps" / f"{run_id}.json", {"run_id": run_id, "gaps": gaps})


def persist_people_review_queue(home: Path, new_person: list[dict[str, Any]]) -> None:
    """Human-readable, append-only triage file for route-entities.py's detected-but-
    unknown names. Mirrors routing-gaps.log's append-across-runs convention; the
    machine-readable form is the per-run workdir/people-review-queue.json."""
    if not new_person:
        return
    path = home / "people-review-queue.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    blocks: list[str] = []
    for item in new_person:
        candidate = item.get("candidate") if isinstance(item.get("candidate"), dict) else {}
        candidate_id = str(item.get("candidate_id") or "")
        content = str(candidate.get("content") or "")[:100]
        names = ", ".join(str(name) for name in (item.get("detected_names") or []))
        source = f"{candidate.get('source_chat')} @ {candidate.get('source_date')}"
        confidence = str(candidate.get("confidence") or "")
        legacy_block = (
            f"### {content}\n"
            f"**Detected names:** {names}\n"
            f"**Source:** {source}\n"
            f"**Confidence:** {confidence}\n\n---\n\n"
        )
        if (candidate_id and f"**Candidate ID:** {candidate_id}\n" in existing) or legacy_block in existing:
            continue
        blocks.append(
            f"### {content}\n"
            f"**Candidate ID:** {candidate_id}\n"
            f"**Detected names:** {names}\n"
            f"**Source:** {source}\n"
            f"**Confidence:** {confidence}\n\n---\n\n"
        )
    if not blocks:
        return
    is_new = not path.is_file()
    with path.open("a", encoding="utf-8") as handle:
        if is_new:
            handle.write("# People review queue\n\nDetected names with no known-page match. Not written to any vault.\n\n")
        handle.writelines(blocks)
    os.chmod(path, 0o600)


def enforce_vault_policy(
    decision: dict[str, Any],
    vault_name: str,
    policies: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Apply deterministic write gates after model reconciliation."""
    enforced = dict(decision)
    if (
        policies.get(vault_name, {}).get("review_only") is True
        and decision.get("action") != "duplicate"
    ):
        enforced["needs_review"] = True
        enforced["vault_policy_review_only"] = True
    if decision.get("policy_review_only") is True and decision.get("action") != "duplicate":
        enforced["needs_review"] = True
    if decision.get("person_review_only") is True and decision.get("action") != "duplicate":
        enforced["needs_review"] = True
    return enforced


def process_batch(
    args: argparse.Namespace,
    start: str,
    end: str,
    start_epoch: int,
    end_epoch: int,
    transcripts: list[Path],
) -> dict[str, Any]:
    attempt_started_at = utc_now()
    run_id = f"dream-{args.source}-{start}-{end}-{end_epoch}"
    undo_log = args.home / "undo" / f"{run_id}.jsonl"
    workdir = args.home / "runs" / run_id
    workdir.mkdir(parents=True, exist_ok=True)
    os.chmod(workdir, 0o700)
    state_path = workdir / "state.json"
    state: dict[str, Any] = {
        "schema_version": 1,
        "run_id": run_id,
        "status": "running",
        "mode": "shadow" if args.shadow else ("dry-run" if args.dry_run else "real"),
        "source": args.source,
        "window": {
            "start": start,
            "end": end,
            "start_epoch": start_epoch,
            "end_epoch": end_epoch,
        },
        "marker_value": str(end_epoch),
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "marker_allowed": False,
        "stages": {},
    }
    if state_path.is_file():
        previous = json.loads(state_path.read_text())
        if previous.get("run_id") == run_id:
            state = previous
            state["status"] = "running"
            state["mode"] = "shadow" if args.shadow else ("dry-run" if args.dry_run else "real")
            state["marker_allowed"] = False
    state.pop("error", None)
    state["stages"] = {}
    state["attempt_started_at"] = attempt_started_at
    state["attempt_pid"] = os.getpid()
    atomic_json(state_path, state)
    runtime_env = os.environ.copy()
    runtime_env.update(
        DREAM_HOME=str(args.home),
        DREAM_QUEUE_FILE=str(args.home / "queue/pending.md"),
        DREAM_MARKER_DIR=str(args.home),
        DREAM_CONFIG=str(args.config),
    )

    try:
        atomic_json(workdir / "find-transcripts.json", [str(path) for path in transcripts])
        manifest: list[dict[str, str]] = []
        for transcript in transcripts:
            if not transcript.is_file():
                raise RunFailure(f"transcript disappeared: {transcript}")
            safe_id = hashlib.sha256(str(transcript).encode()).hexdigest()
            filtered = workdir / f"map-prefilter-{safe_id}.txt"
            result = run(
                [str(SCRIPT_DIR / "prefilter-transcript.py"), "--stats", str(transcript)]
            )
            filtered.write_text(result.stdout, encoding="utf-8")
            os.chmod(filtered, 0o600)
            if result.stdout.strip():
                source_date = datetime.fromtimestamp(transcript.stat().st_mtime).date().isoformat()
                stats = parse_prefilter_stats(result.stderr)
                manifest.append(
                    {
                        "raw": str(transcript),
                        "filtered": str(filtered),
                        "source_date": source_date,
                        **stats,
                    }
                )
        atomic_json(workdir / "map-manifest.json", manifest)
        stage_update(state, state_path, "find", status="success", transcripts=len(transcripts), prefiltered=len(manifest))
        new_person: list[dict[str, Any]] = []

        if not manifest:
            atomic_json(workdir / "map-units.json", [])
            atomic_json(workdir / "map-valid.json", [])
            atomic_json(workdir / "reduced.json", [])
            atomic_json(workdir / "routable.json", [])
            atomic_json(workdir / "route-batches.json", [])
            atomic_json(workdir / "routed-records.json", [])
            atomic_json(args.home / "gaps" / f"{run_id}.json", {"run_id": run_id, "gaps": []})
            atomic_json(workdir / "reconcile-batches.json", [])
            atomic_json(workdir / "reconcile-decisions.json", [])
            for name in ("map", "reduce", "route", "reconcile", "apply"):
                stage_update(state, state_path, name, status="success", total=0, completed=0, failed=0)
            fact_lines: list[dict[str, Any]] = []
            reduced: list[dict[str, Any]] = []
            routed: list[dict[str, Any]] = []
            decisions: list[dict[str, Any]] = []
            audit_candidates: list[dict[str, Any]] = []
            gaps = 0
        else:
            result = run(
                [str(SCRIPT_DIR / "build-map-batches.py"), "--workdir", str(workdir)],
                stdin=json.dumps(manifest),
            )
            (workdir / "map-units.json").write_text(result.stdout, encoding="utf-8")
            os.chmod(workdir / "map-units.json", 0o600)
            agent_stage("map", workdir, SKILL_DIR / "prompts/map.md", args, state, state_path)
            try:
                valid = validate_map(workdir)
            except Exception:
                stage_validation_failed(state, state_path, "map")
                raise
            stage_update(state, state_path, "map", **state["stages"]["map"], valid_candidates=len(valid))

            result = run([str(SCRIPT_DIR / "reduce-dedup.py"), "--report"], stdin=json.dumps(valid))
            reduced_raw = json.loads(result.stdout)
            result = run(
                [str(SCRIPT_DIR / "classify-candidate-policy.py"), "--report"],
                stdin=json.dumps(reduced_raw),
            )
            (workdir / "reduced.json").write_text(result.stdout, encoding="utf-8")
            os.chmod(workdir / "reduced.json", 0o600)
            reduced = json.loads(result.stdout)

            result = run([str(SCRIPT_DIR / "split-memory-tiers.py"), "--report"], stdin=json.dumps(reduced))
            tiers = json.loads(result.stdout)
            routable, audit_candidates, dropped_count = tiers["routable"], tiers["audit"], tiers["dropped"]
            result = run(
                [
                    str(SCRIPT_DIR / "gate-historical-current.py"),
                    "--as-of",
                    datetime.now(timezone.utc).date().isoformat(),
                    "--review-after-days",
                    str(args.historical_current_review_days),
                    "--report",
                ],
                stdin=json.dumps(routable),
            )
            routable = json.loads(result.stdout)
            historical_review = sum(
                1 for candidate in routable if candidate.get("historical_review") is True
            )
            result = run(
                [
                    str(SCRIPT_DIR / "sample-quality-review.py"),
                    "--percent",
                    str(args.quality_review_sample_percent),
                    "--report",
                ],
                stdin=json.dumps(routable),
            )
            routable = json.loads(result.stdout)
            quality_review_sample = sum(
                1 for candidate in routable if candidate.get("quality_review_sample") is True
            )
            policy_review = sum(
                1 for candidate in routable if candidate.get("policy_review_only") is True
            )
            atomic_json(workdir / "routable.json", routable)
            atomic_json(workdir / "audit-candidates.json", audit_candidates)
            stage_update(
                state,
                state_path,
                "reduce",
                status="success",
                input=len(valid),
                output=len(reduced),
                routable=len(routable),
                audit=len(audit_candidates),
                dropped=dropped_count,
                historical_review=historical_review,
                quality_review_sample=quality_review_sample,
                policy_review=policy_review,
            )

            result = run(
                [str(SCRIPT_DIR / "route-entities.py"), "--config", str(args.config), "--report"],
                stdin=json.dumps(routable),
            )
            entity_split = json.loads(result.stdout)
            pre_routed, new_person, remaining = (
                entity_split["pre_routed"],
                entity_split["new_person"],
                entity_split["remaining"],
            )
            atomic_json(workdir / "people-review-queue.json", new_person)
            stage_update(
                state,
                state_path,
                "reduce",
                **state["stages"]["reduce"],
                pre_routed=len(pre_routed),
                new_person=len(new_person),
            )

            result = run(
                [
                    str(SCRIPT_DIR / "build-route-batches.py"),
                    "--config",
                    str(args.config),
                    "--top-k",
                    str(args.route_top_k),
                ],
                stdin=json.dumps(remaining),
            )
            (workdir / "route-batches.json").write_text(result.stdout, encoding="utf-8")
            os.chmod(workdir / "route-batches.json", 0o600)
            agent_stage("route", workdir, SKILL_DIR / "prompts/route.md", args, state, state_path)
            try:
                model_routed = combine_route(workdir, args.config)
                model_routed, fallback_stats = run_route_fallback(args, workdir, model_routed)
                routed = pre_routed + model_routed
                atomic_json(workdir / "routed-records-canonical.json", routed)
                persist_routing_gaps(args.home, run_id, workdir, routed)
            except Exception:
                stage_validation_failed(state, state_path, "route")
                raise
            gaps = sum(1 for record in routed if record["route"]["status"] != "routed")
            stage_update(
                state,
                state_path,
                "route",
                **state["stages"]["route"],
                records=len(routed),
                gaps=gaps,
                fallback=fallback_stats,
            )

            result = run(
                [
                    str(SCRIPT_DIR / "build-reconcile-batches.py"),
                    "--config",
                    str(args.config),
                    "--run-date",
                    end,
                ],
                stdin=json.dumps(routed),
            )
            (workdir / "reconcile-batches.json").write_text(result.stdout, encoding="utf-8")
            os.chmod(workdir / "reconcile-batches.json", 0o600)
            reconcile_batches = json.loads(result.stdout)
            if reconcile_batches:
                agent_stage("reconcile", workdir, SKILL_DIR / "prompts/reconcile.md", args, state, state_path)
                try:
                    decisions = combine_reconcile(workdir)
                except Exception:
                    stage_validation_failed(state, state_path, "reconcile")
                    raise
            else:
                atomic_json(workdir / "reconcile-decisions.json", [])
                decisions = []
                stage_update(state, state_path, "reconcile", status="success", total=0, completed=0, failed=0)

            cross_target_result = run(
                [str(SCRIPT_DIR / "gate-cross-target-conflicts.py"), "--report"],
                stdin=json.dumps(decisions),
            )
            decisions = json.loads(cross_target_result.stdout)
            cross_target_review = sum(
                1
                for record in decisions
                if isinstance(record, dict)
                and isinstance(record.get("decision"), dict)
                and record["decision"].get("cross_target_review") is True
            )
            density_result = run(
                [
                    str(SCRIPT_DIR / "gate-write-density.py"),
                    "--config",
                    str(args.config),
                    "--page-limit",
                    str(args.page_auto_write_limit),
                    "--section-limit",
                    str(args.section_auto_write_limit),
                    "--page-line-threshold",
                    str(args.page_line_review_threshold),
                    "--report",
                ],
                stdin=json.dumps(decisions),
            )
            decisions = json.loads(density_result.stdout)
            atomic_json(workdir / "reconcile-decisions-gated.json", decisions)
            density_review = sum(
                1
                for record in decisions
                if isinstance(record, dict)
                and isinstance(record.get("decision"), dict)
                and record["decision"].get("density_review") is True
            )
            stage_update(
                state,
                state_path,
                "reconcile",
                **state["stages"]["reconcile"],
                density_review=density_review,
                cross_target_review=cross_target_review,
            )

            vaults = load_vault_config(args.config)
            vault_policies = load_vault_policies(args.config)
            candidate_content = {
                str(record.get("candidate_id")): str(
                    (record.get("candidate") or {}).get("content") or ""
                )
                for record in routed
                if record.get("candidate_id")
            }
            candidate_metadata = {
                str(record.get("candidate_id")): record.get("candidate") or {}
                for record in routed
                if record.get("candidate_id")
            }
            fact_lines = []
            apply_errors = 0
            enforced_decisions: list[dict[str, Any]] = []
            for record in decisions:
                candidate_id = record["candidate_id"]
                decision = record["decision"]
                decision_path = workdir / f"decision-{candidate_id}.json"
                metadata = candidate_metadata.get(candidate_id, {})
                enriched_decision = dict(decision)
                enriched_decision["run_id"] = run_id
                enriched_decision["run_window"] = {"start": start, "end": end}
                enriched_decision["model_profile"] = {
                    "engine": args.engine,
                    "map": args.map_model,
                    "route": args.route_model,
                    "reconcile": args.reconcile_model,
                    "efforts": {
                        "map": args.map_effort,
                        "route": args.route_effort,
                        "reconcile": args.reconcile_effort,
                    },
                }
                for source_key, decision_key in (
                    ("type", "candidate_type"),
                    ("memory_tier", "memory_tier"),
                    ("source_role", "source_role"),
                    ("source_date", "source_date"),
                    ("source_chat", "source_chat"),
                    ("source_event", "source_event"),
                    ("evidence", "evidence"),
                    ("historical_review", "historical_review"),
                    ("historical_age_days", "historical_age_days"),
                    ("quality_review_sample", "quality_review_sample"),
                    ("quality_review_bucket", "quality_review_bucket"),
                    ("fact_class", "fact_class"),
                    ("policy_review_only", "policy_review_only"),
                    ("policy_reasons", "policy_reasons"),
                    ("person_review_only", "person_review_only"),
                    ("detected_names", "detected_names"),
                    ("review_kind", "review_kind"),
                ):
                    if source_key in metadata:
                        enriched_decision[decision_key] = metadata[source_key]
                vault_name = decision["target"]["vault"]
                if vault_name not in vaults:
                    raise RunFailure(f"decision references unconfigured vault: {vault_name}")
                enriched_decision = enforce_vault_policy(
                    enriched_decision,
                    vault_name,
                    vault_policies,
                )
                enforced_decisions.append(
                    {"candidate_id": candidate_id, "decision": enriched_decision}
                )
                atomic_json(decision_path, enriched_decision)
                command = [
                    str(SCRIPT_DIR / "apply-decision.sh"),
                    "--vault",
                    str(vaults[vault_name][0]),
                    "--decision",
                    str(decision_path),
                    "--undo-log",
                    str(undo_log),
                    "--candidate-id",
                    candidate_id,
                ]
                if args.dry_run or args.shadow:
                    command.append("--dry-run")
                applied = run(command, check=False, env=runtime_env)
                if applied.returncode != 0:
                    apply_errors += 1
                    continue
                for line in applied.stdout.splitlines():
                    try:
                        value = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(value, dict):
                        if value.get("action") == "duplicate" and not value.get("content"):
                            value["candidate_content"] = candidate_content.get(candidate_id, "")
                        fact_lines.append(value)
            # Metrics and post-run audits must see the exact decisions handed to
            # APPLY, including deterministic candidate, density, cross-target,
            # people, and per-vault review gates.  The earlier reconcile files
            # intentionally preserve pre-enforcement stage outputs.
            atomic_json(workdir / "reconcile-decisions-enforced.json", enforced_decisions)
            stage_update(
                state,
                state_path,
                "apply",
                status="success" if apply_errors == 0 else "failed",
                decisions=len(decisions),
                fact_events=len(fact_lines),
                failed=apply_errors,
            )
            if apply_errors:
                raise RunFailure(f"{apply_errors} decisions failed during apply")

        for candidate in audit_candidates:
            fact_lines.append(
                {
                    "target": "(audit — no vault write)",
                    "content": candidate.get("content", ""),
                    "action": "audit",
                    "review_status": "audit",
                    "confidence": candidate.get("confidence"),
                }
            )

        run_summary = {
            "run_id": run_id,
            "date": end,
            "window_start": start,
            "window_end": end,
            "chats_scanned": len(transcripts),
            "routing": {
                "records": len(routed),
                "gaps": gaps,
                "fallback": state.get("stages", {}).get("route", {}).get("fallback", {}),
            },
            "undo_log": str(undo_log),
            "undo_home": str(args.home),
            "facts": fact_lines,
        }
        atomic_json(workdir / "run-summary.json", run_summary)
        receipt_command = [str(SCRIPT_DIR / "write-receipt.sh"), "--config", str(args.config)]
        if args.dry_run or args.shadow:
            receipt_command.append("--dry-run")
        try:
            receipt = run(receipt_command, stdin=json.dumps(run_summary))
        except Exception:
            stage_update(state, state_path, "receipt", status="failed")
            raise
        stage_update(state, state_path, "receipt", status="success")

        metrics_ended_at = utc_now()
        metrics_command = [
            str(SCRIPT_DIR / "collect-run-metrics.py"),
            "--workdir",
            str(workdir),
            "--run-id",
            run_id,
            "--status",
            "review-only" if args.shadow else ("dry-run" if args.dry_run else "completed"),
            "--source",
            args.source,
            "--window-start",
            start,
            "--window-end",
            end,
            "--chats-found",
            str(len(transcripts)),
            "--chats-prefiltered",
            str(len(manifest)),
            "--started-at",
            attempt_started_at,
            "--ended-at",
            metrics_ended_at,
            "--run-summary",
            str(workdir / "run-summary.json"),
            "--metrics-dir",
            str(args.home / "metrics"),
        ]
        if args.dry_run:
            metrics_command.append("--dry-run")
        try:
            metrics = run(metrics_command)
        except Exception:
            stage_update(state, state_path, "metrics", status="failed")
            raise
        stage_update(state, state_path, "metrics", status="success")

        required = ("find", "map", "reduce", "route", "reconcile", "apply", "receipt")
        ready = all(state["stages"].get(name, {}).get("status") == "success" for name in required)
        state["status"] = "shadow-complete" if args.shadow else ("dry-run" if args.dry_run else "ready-to-advance")
        state["marker_allowed"] = bool(ready and not args.dry_run and not args.shadow)
        state.pop("error", None)
        state["attempt_ended_at"] = utc_now()
        state["updated_at"] = utc_now()
        atomic_json(state_path, state)

        if args.shadow:
            shadow_marker_dir = args.home / "shadow-markers"
            run(
                [
                    str(SCRIPT_DIR / "advance-marker.sh"),
                    "--shadow",
                    "--date",
                    str(end_epoch),
                    "--source",
                    args.source,
                    "--marker-dir",
                    str(shadow_marker_dir),
                    "--run-state",
                    str(state_path),
                ]
            )
            state["shadow_marker_advanced_at"] = utc_now()
            atomic_json(state_path, state)

        if state["marker_allowed"]:
            run(
                [
                    str(SCRIPT_DIR / "advance-marker.sh"),
                    "--date",
                    str(end_epoch),
                    "--source",
                    args.source,
                    "--marker-dir",
                    str(args.home),
                    "--run-state",
                    str(state_path),
                ]
            )
            state["status"] = "completed"
            state["marker_advanced_at"] = utc_now()
            atomic_json(state_path, state)

        completed_snapshot = args.home / "runs" / f"{run_id}.json"
        atomic_json(completed_snapshot, state)
        if not args.keep_artifacts and state["status"] in {"completed", "dry-run", "shadow-complete"}:
            shutil.rmtree(workdir)
        return {
            "run_id": run_id,
            "status": state["status"],
            "transcripts": len(transcripts),
            "candidates": len(reduced),
            "routes": len(routed),
            "gaps": gaps,
            "decisions": len(decisions),
            "outcomes": dict(
                sorted(
                    Counter(
                        str(item.get("review_status") or "unknown")
                        for item in fact_lines
                        if isinstance(item, dict)
                    ).items()
                )
            ),
        }
    except Exception as exc:
        state["status"] = "failed"
        state["marker_allowed"] = False
        state["error"] = str(exc)[:1000]
        state["updated_at"] = utc_now()
        atomic_json(state_path, state)
        append_jsonl(
            args.home / "metrics" / "failures.jsonl",
            {
                "run_id": run_id,
                "recorded_at": utc_now(),
                "error_type": type(exc).__name__,
                "failed_stages": sorted(
                    name
                    for name, stage in state.get("stages", {}).items()
                    if isinstance(stage, dict) and stage.get("status") == "failed"
                ),
            },
        )
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", choices=("claude", "codex", "all"), default="all")
    parser.add_argument("--since")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--resume", help="resume an existing retained run ID")
    parser.add_argument(
        "--promote-shadow",
        action="store_true",
        help="explicitly allow a retained shadow run to resume as a real write",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--shadow",
        action="store_true",
        help="full evaluation with no vault, queue, receipt, or production-marker writes",
    )
    parser.add_argument("--keep-artifacts", action="store_true")
    parser.add_argument("--config", type=Path, default=Path.home() / ".claude/dream-skill/config.toml")
    parser.add_argument("--home", type=Path, default=Path.home() / ".claude/dream-skill")
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument(
        "--engine",
        default=os.environ.get("DREAM_ENGINE", "codex"),
        help="agent CLI for MAP/ROUTE/RECONCILE: codex or claude (independent of --source)",
    )
    parser.add_argument("--codex-bin", default=os.environ.get("CODEX_BIN", "codex"))
    parser.add_argument("--claude-bin", default=os.environ.get("CLAUDE_BIN", "claude"))
    parser.add_argument("--agent-retries", type=int, default=1)
    parser.add_argument("--route-top-k", type=int, default=32)
    parser.add_argument(
        "--historical-current-review-days",
        type=int,
        default=int(os.environ.get("DREAM_HISTORICAL_CURRENT_REVIEW_DAYS", "30")),
        help="force current-tier facts this many days old into review; 0 reviews all current facts",
    )
    parser.add_argument(
        "--quality-review-sample-percent",
        type=int,
        default=int(os.environ.get("DREAM_QUALITY_REVIEW_SAMPLE_PERCENT", "0")),
        help="deterministically send this percent of high-confidence facts through review",
    )
    parser.add_argument("--map-model", default=None)
    parser.add_argument("--map-effort", default=None)
    parser.add_argument("--map-concurrency", type=int, default=4)
    parser.add_argument("--map-timeout", type=int, default=900)
    parser.add_argument("--route-model", default=None)
    parser.add_argument("--route-effort", default=None)
    parser.add_argument(
        "--route-fallback-effort",
        default=os.environ.get("DREAM_ROUTE_FALLBACK_EFFORT"),
        help="reasoning effort for the targeted gap/ambiguous retry (Codex default: medium)",
    )
    parser.add_argument(
        "--no-route-gap-retry",
        dest="route_gap_retry",
        action="store_false",
        help="disable the targeted second ROUTE pass for gap/ambiguous outcomes",
    )
    parser.set_defaults(route_gap_retry=True)
    parser.add_argument("--route-concurrency", type=int, default=6)
    parser.add_argument("--route-timeout", type=int, default=900)
    parser.add_argument("--reconcile-model", default=None)
    parser.add_argument("--reconcile-effort", default=None)
    parser.add_argument("--reconcile-concurrency", type=int, default=6)
    parser.add_argument("--reconcile-timeout", type=int, default=1200)
    parser.add_argument(
        "--page-auto-write-limit",
        type=int,
        default=int(os.environ.get("DREAM_PAGE_AUTO_WRITE_LIMIT", "12")),
        help="queue otherwise-safe writes after this many additions to one page per run; 0 disables",
    )
    parser.add_argument(
        "--section-auto-write-limit",
        type=int,
        default=int(os.environ.get("DREAM_SECTION_AUTO_WRITE_LIMIT", "8")),
        help="queue otherwise-safe writes after this many additions to one section per run; 0 disables",
    )
    parser.add_argument(
        "--page-line-review-threshold",
        type=int,
        default=int(os.environ.get("DREAM_PAGE_LINE_REVIEW_THRESHOLD", "1000")),
        help="queue additions to pages at or above this line count; 0 disables",
    )
    args = parser.parse_args(argv)

    if args.engine not in ENGINES:
        parser.error(f"--engine/DREAM_ENGINE must be one of {ENGINES}, got: {args.engine!r}")
    if args.historical_current_review_days < 0:
        parser.error("--historical-current-review-days must be >= 0")
    if not 0 <= args.quality_review_sample_percent <= 100:
        parser.error("--quality-review-sample-percent must be between 0 and 100")
    if min(
        args.page_auto_write_limit,
        args.section_auto_write_limit,
        args.page_line_review_threshold,
    ) < 0:
        parser.error("write-density limits must be >= 0")
    if sum(bool(value) for value in (args.all, args.since, args.resume)) > 1:
        parser.error("--all, --since, and --resume are mutually exclusive")
    if args.promote_shadow and not args.resume:
        parser.error("--promote-shadow requires --resume")
    args.home = args.home.expanduser().resolve()
    args.config = args.config.expanduser().resolve()
    args.cwd = args.cwd.expanduser().resolve()
    resolve_stage_agent_defaults(args)
    if args.route_fallback_effort is None and args.engine == "codex":
        args.route_fallback_effort = "medium"
    try:
        validate_environment(args)
    except RunFailure as exc:
        print(f"dream-run: preflight failed: {exc}", file=sys.stderr)
        return 2
    args.home.mkdir(parents=True, exist_ok=True)
    os.chmod(args.home, 0o700)
    (args.home / "runs").mkdir(exist_ok=True)
    os.chmod(args.home / "runs", 0o700)

    lock_path = args.home / "run.lock"
    with lock_path.open("a+") as lock:
        os.chmod(lock_path, 0o600)
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("dream-run: another run holds the global lock", file=sys.stderr)
            return 1

        if args.resume:
            resume_dir = args.home / "runs" / args.resume
            resume_state = load_json(resume_dir / "state.json") if (resume_dir / "state.json").is_file() else None
            if not isinstance(resume_state, dict):
                print(f"dream-run: retained run not found: {args.resume}", file=sys.stderr)
                return 1
            stored_mode = resume_state.get("mode")
            requested_mode = "shadow" if args.shadow else ("dry-run" if args.dry_run else "real")
            if stored_mode and stored_mode != requested_mode:
                allowed_promotion = (
                    stored_mode == "shadow"
                    and requested_mode == "real"
                    and args.promote_shadow
                )
                if not allowed_promotion:
                    print(
                        f"dream-run: retained run mode is {stored_mode}; requested {requested_mode}",
                        file=sys.stderr,
                    )
                    return 1
            window = resume_state.get("window")
            if not isinstance(window, dict) or not all(
                key in window for key in ("start", "end", "start_epoch", "end_epoch")
            ):
                print(f"dream-run: retained run has no resumable window: {args.resume}", file=sys.stderr)
                return 1
            args.source = str(resume_state.get("source") or args.source)
            find_transcripts_path = resume_dir / "find-transcripts.json"
            transcript_values = load_json(find_transcripts_path) if find_transcripts_path.is_file() else None
            if not isinstance(transcript_values, list):
                manifest = load_json(resume_dir / "map-manifest.json")
                transcript_values = [item.get("raw") for item in manifest if isinstance(item, dict)] if isinstance(manifest, list) else []
            transcripts = [Path(value) for value in transcript_values if isinstance(value, str)]
            result = process_batch(
                args,
                str(window["start"]),
                str(window["end"]),
                int(window["start_epoch"]),
                int(window["end_epoch"]),
                transcripts,
            )
            print(json.dumps({"runs": [result]}, indent=2, ensure_ascii=False))
            return 0

        find_command = [str(SCRIPT_DIR / "find-chats.sh"), "--source", args.source]
        if args.all:
            find_command.append("--all")
        elif args.since:
            find_command.extend(["--since", args.since])
        env = os.environ.copy()
        marker_dir = args.home / "shadow-markers" if args.shadow else args.home
        env.update(DREAM_HOME=str(args.home), DREAM_MARKER_DIR=str(marker_dir), DREAM_CONFIG=str(args.config))
        found = run(find_command, env=env)
        batches = parse_batches(found.stdout)
        if not batches:
            print("dream-run: no BATCH header emitted", file=sys.stderr)
            return 1
        results = []
        try:
            for start, end, start_epoch, end_epoch, transcripts in batches:
                results.append(process_batch(args, start, end, start_epoch, end_epoch, transcripts))
        except Exception as exc:
            print(f"dream-run: {exc}", file=sys.stderr)
            return 1
        print(json.dumps({"runs": results}, indent=2, ensure_ascii=False))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
