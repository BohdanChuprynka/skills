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

from vault_search import load_vault_config


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent

ENGINES = ("codex", "claude")
STAGE_MODEL_DEFAULTS = {
    "codex": {"map": "gpt-5.6-luna", "route": "gpt-5.6-luna", "reconcile": "gpt-5.6-terra"},
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


def stage_update(state: dict[str, Any], path: Path, stage: str, **values: Any) -> None:
    state.setdefault("stages", {})[stage] = {"updated_at": utc_now(), **values}
    state["updated_at"] = utc_now()
    atomic_json(path, state)


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
        "collect-run-metrics.py",
        "find-chats.sh",
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
    result = run(command, check=False)
    summary_path = workdir / f"{stage}-run-summary.json"
    summary = json.loads(summary_path.read_text()) if summary_path.is_file() else {}
    stage_update(
        state,
        state_path,
        stage,
        status="success" if result.returncode == 0 else "failed",
        total=summary.get("tasks"),
        completed=summary.get("completed"),
        failed=summary.get("failed"),
        prompt_sha256=summary.get("prompt_sha256"),
    )
    if result.returncode != 0:
        raise RunFailure(f"{stage} agents left unresolved batches; see {summary_path}")


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
    retrieval: dict[str, list[dict[str, str]]] = {}
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
                {"vault": str(catalog[page_id].get("vault")), "page": str(catalog[page_id].get("page"))}
                for page_id in item.get("allowed_page_ids", [])[:5]
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
    is_new = not path.is_file()
    with path.open("a", encoding="utf-8") as handle:
        if is_new:
            handle.write("# People review queue\n\nDetected names with no known-page match. Not written to any vault.\n\n")
        for item in new_person:
            candidate = item.get("candidate") if isinstance(item.get("candidate"), dict) else {}
            content = str(candidate.get("content") or "")[:100]
            names = ", ".join(str(name) for name in (item.get("detected_names") or []))
            handle.write(f"### {content}\n")
            handle.write(f"**Detected names:** {names}\n")
            handle.write(f"**Source:** {candidate.get('source_chat')} @ {candidate.get('source_date')}\n")
            handle.write(f"**Confidence:** {candidate.get('confidence')}\n")
            handle.write("\n---\n\n")
    os.chmod(path, 0o600)


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
                manifest.append(
                    {"raw": str(transcript), "filtered": str(filtered), "source_date": source_date}
                )
        atomic_json(workdir / "map-manifest.json", manifest)
        stage_update(state, state_path, "find", status="success", transcripts=len(transcripts), prefiltered=len(manifest))

        if not manifest:
            atomic_json(workdir / "map-units.json", [])
            atomic_json(workdir / "map-valid.json", [])
            atomic_json(workdir / "reduced.json", [])
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
                stage_update(state, state_path, "map", **state["stages"]["map"], status="failed", validation_failed=True)
                raise
            stage_update(state, state_path, "map", **state["stages"]["map"], valid_candidates=len(valid))

            result = run([str(SCRIPT_DIR / "reduce-dedup.py"), "--report"], stdin=json.dumps(valid))
            (workdir / "reduced.json").write_text(result.stdout, encoding="utf-8")
            os.chmod(workdir / "reduced.json", 0o600)
            reduced = json.loads(result.stdout)

            result = run([str(SCRIPT_DIR / "split-memory-tiers.py"), "--report"], stdin=json.dumps(reduced))
            tiers = json.loads(result.stdout)
            routable, audit_candidates, dropped_count = tiers["routable"], tiers["audit"], tiers["dropped"]
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
            if not (args.dry_run or args.shadow):
                persist_people_review_queue(args.home, new_person)
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
                routed = combine_route(workdir, args.config)
                persist_routing_gaps(args.home, run_id, workdir, routed)
                routed = pre_routed + routed
            except Exception:
                stage_update(state, state_path, "route", **state["stages"]["route"], status="failed", validation_failed=True)
                raise
            gaps = sum(1 for record in routed if record["route"]["status"] != "routed")
            stage_update(state, state_path, "route", **state["stages"]["route"], records=len(routed), gaps=gaps)

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
                    stage_update(
                        state,
                        state_path,
                        "reconcile",
                        **state["stages"]["reconcile"],
                        status="failed",
                        validation_failed=True,
                    )
                    raise
            else:
                atomic_json(workdir / "reconcile-decisions.json", [])
                decisions = []
                stage_update(state, state_path, "reconcile", status="success", total=0, completed=0, failed=0)

            vaults = load_vault_config(args.config)
            fact_lines = []
            apply_errors = 0
            for record in decisions:
                candidate_id = record["candidate_id"]
                decision = record["decision"]
                decision_path = workdir / f"decision-{candidate_id}.json"
                atomic_json(decision_path, decision)
                vault_name = decision["target"]["vault"]
                if vault_name not in vaults:
                    raise RunFailure(f"decision references unconfigured vault: {vault_name}")
                command = [
                    str(SCRIPT_DIR / "apply-decision.sh"),
                    "--vault",
                    str(vaults[vault_name][0]),
                    "--decision",
                    str(decision_path),
                    "--undo-log",
                    str(args.home / "undo" / f"{end}.jsonl"),
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
                        fact_lines.append(value)
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
    parser.add_argument("--map-model", default=None)
    parser.add_argument("--map-effort", default=None)
    parser.add_argument("--map-concurrency", type=int, default=4)
    parser.add_argument("--map-timeout", type=int, default=900)
    parser.add_argument("--route-model", default=None)
    parser.add_argument("--route-effort", default=None)
    parser.add_argument("--route-concurrency", type=int, default=6)
    parser.add_argument("--route-timeout", type=int, default=900)
    parser.add_argument("--reconcile-model", default=None)
    parser.add_argument("--reconcile-effort", default=None)
    parser.add_argument("--reconcile-concurrency", type=int, default=6)
    parser.add_argument("--reconcile-timeout", type=int, default=1200)
    args = parser.parse_args(argv)

    if args.engine not in ENGINES:
        parser.error(f"--engine/DREAM_ENGINE must be one of {ENGINES}, got: {args.engine!r}")
    if sum(bool(value) for value in (args.all, args.since, args.resume)) > 1:
        parser.error("--all, --since, and --resume are mutually exclusive")
    if args.promote_shadow and not args.resume:
        parser.error("--promote-shadow requires --resume")
    args.home = args.home.expanduser().resolve()
    args.config = args.config.expanduser().resolve()
    args.cwd = args.cwd.expanduser().resolve()
    resolve_stage_agent_defaults(args)
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
