#!/usr/bin/env python3
"""Run MAP, ROUTE, or RECONCILE Codex batches with retries and resumable outputs."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


STAGES = {"map", "route", "reconcile"}
ENGINES = {"codex", "claude"}
NON_RETRYABLE_LOG_FRAGMENTS = (
    "you've hit your usage limit",
    "usage limit",
    "authentication failed",
    "invalid api key",
    "model not found",
    "unsupported model",
    "usage limit reached",
    "rate limit",
    "rate_limit_error",
    "credit balance is too low",
    "insufficient_quota",
    "invalid x-api-key",
    "authentication_error",
)


def parse_positive(value: str, name: str, allow_zero: bool = False) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    minimum = 0 if allow_zero else 1
    if parsed < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    return parsed


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def expected_ids(stage: str, task: dict[str, Any]) -> set[str] | None:
    if stage == "map":
        return None
    return {
        str(item["candidate_id"])
        for item in task.get("candidates", [])
        if isinstance(item, dict) and item.get("candidate_id")
    }


def valid_output(path: Path, expected: set[str] | None) -> tuple[bool, int]:
    if not path.is_file():
        return False, 0
    try:
        payload = load_json(path)
    except (OSError, json.JSONDecodeError):
        return False, 0
    if not isinstance(payload, list):
        return False, 0
    if expected is not None:
        ids = {
            str(item.get("candidate_id"))
            for item in payload
            if isinstance(item, dict) and item.get("candidate_id")
        }
        if ids != expected or len(payload) != len(expected):
            return False, len(payload)
    return True, len(payload)


def normalize_claude_json_array(path: Path) -> None:
    """Canonicalize a Claude text response only when it contains a JSON array.

    Claude's text output occasionally encloses an otherwise-valid final array in
    a Markdown fence or a short preamble.  Keep invalid output intact for the
    normal validator/retry path; only replace the file after JSON parsing proves
    that the extracted value is an array.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return
    candidate = raw.strip()
    fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", candidate, flags=re.DOTALL | re.IGNORECASE)
    if fence:
        candidate = fence.group(1).strip()
    else:
        try:
            json.loads(candidate)
        except json.JSONDecodeError:
            start, end = candidate.find("["), candidate.rfind("]")
            if start == -1 or end <= start:
                return
            candidate = candidate[start : end + 1]
    try:
        if not isinstance(json.loads(candidate), list):
            return
    except json.JSONDecodeError:
        return
    path.write_text(candidate + "\n", encoding="utf-8")


def task_fingerprint(task: dict[str, Any], input_path: Path, prompt_hash: str) -> str:
    digest = hashlib.sha256()
    digest.update(prompt_hash.encode("ascii"))
    digest.update(json.dumps(task, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    digest.update(input_path.read_bytes())
    return digest.hexdigest()


def materialize_task(stage: str, workdir: Path, task: dict[str, Any]) -> tuple[Path, Path]:
    batch_id = str(task["batch_id"])
    if stage == "map":
        return Path(task["unit_path"]), workdir / f"map-out-{batch_id}.json"
    batch_path = workdir / f"{batch_id}.json"
    rendered = json.dumps(task, indent=2, ensure_ascii=False) + "\n"
    if not batch_path.is_file() or batch_path.read_text(encoding="utf-8") != rendered:
        batch_path.write_text(rendered, encoding="utf-8")
        os.chmod(batch_path, 0o600)
    return batch_path, workdir / f"{stage}-out-{batch_id}.json"


def task_prompt(
    stage: str,
    instructions: Path,
    task: dict[str, Any],
    input_path: Path,
    output_path: Path,
    routing_rules: Path | None,
) -> str:
    lines = [
        f"Follow the trusted batch-processing contract at: {instructions}",
        f"stage: {stage}",
        f"batch_id: {task['batch_id']}",
        f"input_path: {input_path}",
        f"output_path: {output_path}",
    ]
    if routing_rules is not None:
        lines.append(f"routing_rules_path: {routing_rules}")
    if stage == "map":
        lines.append(f"kind: {task.get('kind')}")
        if task.get("kind") == "chunk":
            lines.extend(
                [
                    f"source_chat: {task.get('source_chat')}",
                    f"source_date: {task.get('source_date')}",
                    f"part: {task.get('part')} of {task.get('of')}",
                ]
            )
        else:
            lines.append("Use the in-band separators to assign source_chat and source_date.")
    lines.append(
        "Read each trusted file once. Do not modify any file. Return only the JSON array as your final response; the runner captures it at output_path."
    )
    return "\n".join(lines) + "\n"


def codex_command(args: argparse.Namespace, output_path: Path) -> list[str]:
    command = [
        args.codex_bin,
        "-a",
        "never",
    ]
    if args.model:
        command.extend(["-m", args.model])
    if args.effort:
        command.extend(["-c", f'model_reasoning_effort="{args.effort}"'])
    command.extend(
        [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "-C",
            str(args.cwd),
            "-o",
            str(output_path),
        ]
    )
    return command


def claude_command(args: argparse.Namespace) -> list[str]:
    add_dirs: list[Path] = []
    for candidate in (
        args.workdir,
        args.instructions.parent,
        args.routing_rules.parent if args.routing_rules else None,
    ):
        if candidate is None:
            continue
        resolved = candidate.resolve()
        if resolved not in add_dirs:
            add_dirs.append(resolved)
    command = [
        args.claude_bin,
        "-p",
        "--output-format",
        "text",
        "--permission-mode",
        "acceptEdits",
        "--allowedTools",
        "Read",
        "Glob",
        "Grep",
    ]
    for directory in add_dirs:
        command.extend(["--add-dir", str(directory)])
    if args.model:
        command.extend(["--model", args.model])
    return command


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", required=True, choices=sorted(STAGES))
    parser.add_argument("--workdir", required=True, type=Path)
    parser.add_argument("--instructions", required=True, type=Path)
    parser.add_argument("--routing-rules", type=Path)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument(
        "--engine",
        choices=sorted(ENGINES),
        default="codex",
        help="agent CLI that executes this stage (independent of transcript --source)",
    )
    parser.add_argument("--codex-bin", default=os.environ.get("CODEX_BIN", "codex"))
    parser.add_argument("--claude-bin", default=os.environ.get("CLAUDE_BIN", "claude"))
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--concurrency", default="4")
    parser.add_argument("--timeout", default="900")
    parser.add_argument("--retries", default="1")
    args = parser.parse_args(argv)

    try:
        concurrency = parse_positive(args.concurrency, "--concurrency")
        timeout = parse_positive(args.timeout, "--timeout")
        retries = parse_positive(args.retries, "--retries", allow_zero=True)
        args.workdir.mkdir(parents=True, exist_ok=True)
        os.chmod(args.workdir, 0o700)
        if not args.instructions.is_file():
            raise ValueError(f"instructions not found: {args.instructions}")
        source_name = "map-units.json" if args.stage == "map" else f"{args.stage}-batches.json"
        tasks = load_json(args.workdir / source_name)
        if not isinstance(tasks, list):
            raise ValueError(f"{source_name} must contain a JSON array")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"run-agent-batches: {exc}", file=sys.stderr)
        return 1

    prompt_hash = hashlib.sha256(args.instructions.read_bytes()).hexdigest()
    previous_summary_path = args.workdir / f"{args.stage}-run-summary.json"
    try:
        previous_summary = load_json(previous_summary_path)
    except (OSError, json.JSONDecodeError):
        previous_summary = {}
    previous_fingerprints = {
        str(result.get("batch_id")): str(result.get("fingerprint"))
        for result in previous_summary.get("results", [])
        if isinstance(result, dict) and result.get("batch_id") and result.get("fingerprint")
    } if isinstance(previous_summary, dict) else {}

    def run_one(task: dict[str, Any]) -> dict[str, Any]:
        batch_id = str(task.get("batch_id") or "")
        if not batch_id:
            return {"batch_id": "", "status": "invalid-task", "error": "missing batch_id"}
        input_path, output_path = materialize_task(args.stage, args.workdir, task)
        expected = expected_ids(args.stage, task)
        fingerprint = task_fingerprint(task, input_path, prompt_hash)
        valid, count = valid_output(output_path, expected)
        if valid and previous_fingerprints.get(batch_id) == fingerprint:
            return {
                "batch_id": batch_id,
                "status": "skipped-existing",
                "count": count,
                "attempts": 0,
                "fingerprint": fingerprint,
            }
        prompt_path = args.workdir / f"{args.stage}-prompt-{batch_id}.txt"
        prompt_path.write_text(
            task_prompt(args.stage, args.instructions, task, input_path, output_path, args.routing_rules),
            encoding="utf-8",
        )
        os.chmod(prompt_path, 0o600)
        started = time.monotonic()
        last_status = "failed"
        attempts_done = 0
        for attempt in range(1, retries + 2):
            attempts_done = attempt
            log = args.workdir / f"{args.stage}-log-{batch_id}-attempt-{attempt:02d}.txt"
            for path in (output_path, log):
                path.unlink(missing_ok=True)
            try:
                if args.engine == "claude":
                    with prompt_path.open("rb") as stdin, output_path.open("wb") as stdout, log.open(
                        "wb"
                    ) as stderr:
                        proc = subprocess.run(
                            claude_command(args),
                            stdin=stdin,
                            stdout=stdout,
                            stderr=stderr,
                            timeout=timeout,
                            check=False,
                        )
                else:
                    with prompt_path.open("rb") as stdin, log.open("wb") as stdout:
                        proc = subprocess.run(
                            codex_command(args, output_path),
                            stdin=stdin,
                            stdout=stdout,
                            stderr=subprocess.STDOUT,
                            timeout=timeout,
                            check=False,
                        )
                os.chmod(log, 0o600)
                if proc.returncode != 0:
                    last_status = f"agent-exit-{proc.returncode}"
                    log_text = log.read_text(encoding="utf-8", errors="ignore").casefold()
                    if any(fragment in log_text for fragment in NON_RETRYABLE_LOG_FRAGMENTS):
                        last_status = "non-retryable-agent-error"
                        break
                    continue
                if args.engine == "claude":
                    normalize_claude_json_array(output_path)
            except subprocess.TimeoutExpired:
                last_status = "timeout"
                continue
            valid, count = valid_output(output_path, expected)
            if valid:
                os.chmod(output_path, 0o600)
                return {
                    "batch_id": batch_id,
                    "status": "ok",
                    "count": count,
                    "attempts": attempt,
                    "seconds": round(time.monotonic() - started, 3),
                    "fingerprint": fingerprint,
                }
            last_status = "invalid-or-missing-output"
        return {
            "batch_id": batch_id,
            "status": last_status,
            "attempts": attempts_done,
            "seconds": round(time.monotonic() - started, 3),
            "fingerprint": fingerprint,
        }

    results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(run_one, task) for task in tasks]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)

    results.sort(key=lambda result: str(result.get("batch_id")))
    failures = [result for result in results if result["status"] not in {"ok", "skipped-existing"}]
    summary = {
        "stage": args.stage,
        "prompt_sha256": prompt_hash,
        "tasks": len(tasks),
        "completed": len(tasks) - len(failures),
        "failed": len(failures),
        "results": results,
    }
    summary_path = args.workdir / f"{args.stage}-run-summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(summary_path, 0o600)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
