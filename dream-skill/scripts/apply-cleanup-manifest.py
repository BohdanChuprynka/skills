#!/usr/bin/env python3
"""Transactionally apply a reviewed Dream cleanup manifest.

The default is a content-free dry run.  ``--apply`` requires every source line
and canonical target to prevalidate before the first mutation.  All mutations
flow through ``vault-writer.sh`` into one run-scoped undo log; any failure
automatically rolls the whole cleanup transaction back.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
WRITER = SCRIPT_DIR / "vault-writer.sh"
UNDO = SCRIPT_DIR / "apply-undo.sh"


def safe_run_id(value: str) -> str:
    if (
        not value
        or len(value) > 128
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value)
    ):
        raise ValueError(
            "run ID must be 1-128 characters, start alphanumeric, and use only "
            "letters, digits, dot, underscore, or hyphen"
        )
    return value


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def vault_roots(config: Path) -> dict[str, Path]:
    with config.open("rb") as handle:
        data = tomllib.load(handle)
    result: dict[str, Path] = {}
    for name, value in (data.get("vaults") or {}).items():
        if isinstance(value, dict) and isinstance(value.get("root"), str):
            result[str(name)] = Path(value["root"]).expanduser().resolve()
    return result


def confined(root: Path, relative: str) -> Path:
    rel = Path(relative)
    if rel.is_absolute() or ".." in rel.parts:
        raise ValueError(f"unsafe relative page: {relative}")
    candidate = root / rel
    parent = candidate.parent.resolve()
    if parent != root and root not in parent.parents:
        raise ValueError(f"page escapes vault root: {relative}")
    if candidate.is_symlink():
        raise ValueError(f"refusing symlinked page: {relative}")
    return candidate


def exact_line_count(path: Path, content: str) -> int:
    target = f"- {content}"
    return sum(line == target for line in path.read_text(encoding="utf-8").splitlines())


def validate_manifest(manifest: dict[str, Any], roots: dict[str, Path]) -> list[dict[str, Any]]:
    recommendations = manifest.get("recommendations")
    if not isinstance(recommendations, list) or not recommendations:
        raise ValueError("manifest has no recommendations")
    validated: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    seen_indices: set[int] = set()
    for item in recommendations:
        if not isinstance(item, dict) or item.get("confidence") != "high":
            raise ValueError("every cleanup recommendation must be a high-confidence object")
        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        vault_name = str(source.get("vault") or "")
        root = roots.get(vault_name)
        if root is None:
            raise ValueError(f"source vault is not configured: {vault_name}")
        page = str(source.get("page") or "")
        section = str(source.get("section") or "")
        content = str(source.get("content") or "")
        if not page or not section or not content or "\n" in content or "\r" in content:
            raise ValueError("source page, section, and one-line content are required")
        path = confined(root, page)
        if not path.is_file() or exact_line_count(path, content) != 1:
            raise ValueError(f"source line is not present exactly once: {vault_name}/{page}")
        key = (str(root), page, content)
        if key in seen:
            raise ValueError(f"duplicate cleanup source: {vault_name}/{page}")
        seen.add(key)
        action = item.get("recommended_action")
        if action not in {"remove", "move", "rewrite"}:
            raise ValueError(f"unsupported cleanup action: {action}")
        enriched = dict(item)
        enriched["source_root"] = str(root)
        enriched["source_path"] = str(path)
        if action == "rewrite":
            replacement = item.get("recommended_content")
            if not isinstance(replacement, str) or not replacement or "\n" in replacement or "\r" in replacement:
                raise ValueError("rewrite requires one-line recommended_content")
            if replacement != content and exact_line_count(path, replacement):
                raise ValueError(f"rewrite would duplicate an existing line: {vault_name}/{page}")
        if action == "move":
            target = item.get("canonical_target") if isinstance(item.get("canonical_target"), dict) else {}
            target_vault = str(target.get("vault") or "")
            target_root = roots.get(target_vault)
            if target_root is None:
                raise ValueError(f"move target vault is not configured: {target_vault}")
            target_page = str(target.get("page") or "")
            target_section = str(target.get("section") or "")
            target_path = confined(target_root, target_page)
            if not target_path.is_file() or not target_section:
                raise ValueError(f"move target page/section is invalid: {target_vault}/{target_page}")
            if exact_line_count(target_path, content):
                raise ValueError(f"move target already contains the exact fact: {target_vault}/{target_page}")
            enriched["target_root"] = str(target_root)
            enriched["target_path"] = str(target_path)
        index = item.get("cohort_index")
        if not isinstance(index, int) or index in seen_indices:
            raise ValueError("cohort_index must be a unique integer")
        dependencies = item.get("depends_on", [])
        if not isinstance(dependencies, list) or not all(isinstance(value, int) for value in dependencies):
            raise ValueError(f"cleanup item {index} has invalid depends_on")
        missing_dependencies = [value for value in dependencies if value not in seen_indices]
        if missing_dependencies:
            raise ValueError(f"cleanup item {index} must follow dependencies: {missing_dependencies}")
        seen_indices.add(index)
        validated.append(enriched)
    return validated


def run_writer(arguments: list[str]) -> None:
    result = subprocess.run([str(WRITER), *arguments], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "vault-writer failed")


def create_backups(items: list[dict[str, Any]], backup_dir: Path) -> list[dict[str, str]]:
    pages: dict[str, Path] = {}
    for item in items:
        pages[item["source_path"]] = Path(item["source_path"])
        if item.get("target_path"):
            pages[item["target_path"]] = Path(item["target_path"])
    backup_dir.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(backup_dir.parent, 0o700)
    backup_dir.mkdir(exist_ok=False)
    os.chmod(backup_dir, 0o700)
    records: list[dict[str, str]] = []
    for number, (original_key, original) in enumerate(sorted(pages.items()), 1):
        backup = backup_dir / f"{number:04d}-{hashlib.sha256(original_key.encode()).hexdigest()[:16]}.md"
        shutil.copy2(original, backup)
        os.chmod(backup, 0o600)
        records.append({"original": original_key, "backup": str(backup)})
    mapping = backup_dir / "manifest.json"
    mapping.write_text(json.dumps({"pages": records}, indent=2) + "\n", encoding="utf-8")
    os.chmod(mapping, 0o600)
    return records


def restore_backups(records: list[dict[str, str]]) -> None:
    for record in records:
        original = Path(record["original"])
        backup = Path(record["backup"])
        temp = original.with_name(f".{original.name}.cleanup-restore.{os.getpid()}")
        shutil.copy2(backup, temp)
        os.replace(temp, original)


def retire_undo_log(undo_log: Path) -> Path | None:
    """Move a failed transaction's undo log out of the active run namespace."""
    if not undo_log.is_file():
        return None
    retired = undo_log.with_suffix(".jsonl.rolled-back")
    serial = 1
    while retired.exists():
        retired = undo_log.with_suffix(f".jsonl.rolled-back.{serial}")
        serial += 1
    os.replace(undo_log, retired)
    return retired


def persist_receipt(receipt: dict[str, Any], receipt_path: Path) -> None:
    """Atomically publish one receipt without replacing an existing run receipt."""
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(receipt_path.parent, 0o700)
    if receipt_path.exists():
        raise FileExistsError(f"cleanup receipt already exists: {receipt_path}")
    temp = receipt_path.with_name(f".{receipt_path.name}.tmp.{os.getpid()}")
    published = False
    try:
        with temp.open("x", encoding="utf-8") as handle:
            os.chmod(temp, 0o600)
            handle.write(json.dumps(receipt, indent=2) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        # A hard link publishes the fully written inode atomically and refuses
        # to overwrite a receipt that appeared after the existence check.
        os.link(temp, receipt_path)
        published = True
        temp.unlink()
        directory_fd = os.open(receipt_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError:
        if published:
            receipt_path.unlink(missing_ok=True)
        temp.unlink(missing_ok=True)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--config", type=Path, default=Path.home() / ".claude/dream-skill/config.toml")
    parser.add_argument("--home", type=Path, default=Path.home() / ".claude/dream-skill")
    parser.add_argument("--run-id")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    try:
        manifest = load_json(args.manifest)
        if not isinstance(manifest, dict):
            raise ValueError("manifest must be a JSON object")
        roots = vault_roots(args.config)
        recommendations = validate_manifest(manifest, roots)
        manifest_hash = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
        default_id = f"cleanup-{manifest.get('manifest_id', 'dream')}"
        run_id = safe_run_id(args.run_id or default_id)
    except (OSError, ValueError, json.JSONDecodeError, tomllib.TOMLDecodeError) as exc:
        print(f"apply-cleanup-manifest: preflight failed: {exc}", file=sys.stderr)
        return 2

    counts = Counter(str(item["recommended_action"]) for item in recommendations)
    preview = {
        "run_id": run_id,
        "mode": "apply" if args.apply else "dry-run",
        "manifest_sha256": manifest_hash,
        "recommendations": len(recommendations),
        "actions": dict(sorted(counts.items())),
    }
    if not args.apply:
        print(json.dumps(preview, indent=2))
        return 0

    undo_log = args.home / "undo" / f"{run_id}.jsonl"
    if undo_log.exists():
        print(f"apply-cleanup-manifest: undo log already exists: {undo_log}", file=sys.stderr)
        return 2
    undo_log.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(undo_log.parent, 0o700)
    cleanup_root = args.home / "cleanup"
    cleanup_root.mkdir(parents=True, exist_ok=True)
    os.chmod(cleanup_root, 0o700)
    lock_path = cleanup_root / "cleanup.lock"
    lock_handle = lock_path.open("a+")
    os.chmod(lock_path, 0o600)
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("apply-cleanup-manifest: another cleanup transaction is active", file=sys.stderr)
        return 1
    backup_dir = cleanup_root / "backups" / run_id
    receipt_path = cleanup_root / "runs" / f"{run_id}.json"
    if receipt_path.exists():
        print(f"apply-cleanup-manifest: cleanup receipt already exists: {receipt_path}", file=sys.stderr)
        return 2
    try:
        backups = create_backups(recommendations, backup_dir)
    except (OSError, FileExistsError) as exc:
        print(f"apply-cleanup-manifest: backup preflight failed: {exc}", file=sys.stderr)
        return 2

    try:
        for item in recommendations:
            source = item["source"]
            index = str(item.get("cohort_index") or "unknown")
            common = [
                "--vault", item["source_root"],
                "--page", source["page"],
                "--section", source["section"],
                "--undo-log", str(undo_log),
                "--run-id", run_id,
                "--no-index-update",
            ]
            action = item["recommended_action"]
            if action == "move":
                target = item["canonical_target"]
                run_writer([
                    "--vault", item["target_root"],
                    "--page", target["page"],
                    "--section", target["section"],
                    "--content", source["content"],
                    "--mode", "append",
                    "--undo-log", str(undo_log),
                    "--run-id", run_id,
                    "--candidate-id", f"cleanup-{index}-move-target",
                    "--no-index-update",
                ])
                run_writer([
                    *common,
                    "--content", source["content"],
                    "--mode", "remove",
                    "--candidate-id", f"cleanup-{index}-move-source",
                ])
            elif action == "rewrite":
                run_writer([
                    *common,
                    "--content", f"- {item['recommended_content']}",
                    "--old-content", f"- {source['content']}",
                    "--mode", "replace",
                    "--candidate-id", f"cleanup-{index}-rewrite",
                ])
            else:
                run_writer([
                    *common,
                    "--content", source["content"],
                    "--mode", "remove",
                    "--candidate-id", f"cleanup-{index}-remove",
                ])
        receipt = {
            **preview,
            "status": "applied",
            "applied_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "undo_log": str(undo_log),
            "backup_dir": str(backup_dir),
        }
        persist_receipt(receipt, receipt_path)
    except (OSError, RuntimeError) as exc:
        rollback_errors: list[str] = []
        restored = False
        try:
            restore_backups(backups)
            restored = True
        except OSError as rollback_exc:
            rollback_errors.append(f"vault restore failed: {rollback_exc}")
        # If backup restoration itself is incomplete, retain the active undo
        # log as a second recovery path.  Once byte restoration succeeds, the
        # mutation log no longer describes live state and must leave the active
        # namespace so it cannot be applied a second time accidentally.
        if restored:
            try:
                retire_undo_log(undo_log)
            except OSError as rollback_exc:
                rollback_errors.append(f"undo retirement failed: {rollback_exc}")
        if rollback_errors:
            print(
                "apply-cleanup-manifest: transaction failed and rollback was incomplete: "
                f"{exc}; {'; '.join(rollback_errors)}",
                file=sys.stderr,
            )
            return 1
        print(f"apply-cleanup-manifest: transaction failed and was rolled back: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
