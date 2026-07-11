#!/usr/bin/env python3
"""Archive legacy Dream queue state and retain only transactionally applyable entries."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


BLOCK_RE = re.compile(r"(?ms)^### .*?^---\s*$")
ID_RE = re.compile(r"(?m)^\*\*ID:\*\*\s*(\S+)\s*$")


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temp.write_text(text, encoding="utf-8")
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def atomic_json(path: Path, value: Any) -> None:
    atomic_text(path, json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home() / ".claude/dream-skill")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--archive-name")
    args = parser.parse_args()

    home = args.home.expanduser().resolve()
    queue = home / "queue"
    pending_path = queue / "pending.md"
    decisions_path = queue / "review-decisions.json"
    review_path = queue / "review-input.json"
    sidecars_dir = queue / "sidecars"
    pending = pending_path.read_text(encoding="utf-8", errors="ignore") if pending_path.is_file() else ""
    blocks = BLOCK_RE.findall(pending)
    by_id: dict[str, str] = {}
    missing_id = 0
    for block in blocks:
        match = ID_RE.search(block)
        if match:
            by_id[match.group(1)] = block.strip() + "\n"
        else:
            missing_id += 1
    sidecar_paths = {path.stem: path for path in sidecars_dir.glob("*.json")}
    keep_ids = set(by_id) & set(sidecar_paths)
    orphan_pending = set(by_id) - set(sidecar_paths)
    orphan_sidecars = set(sidecar_paths) - set(by_id)

    report = {
        "pending_blocks": len(blocks),
        "applyable": len(keep_ids),
        "orphan_pending": len(orphan_pending) + missing_id,
        "orphan_sidecars": len(orphan_sidecars),
        "applied": args.apply,
    }
    if not args.apply:
        print(json.dumps(report, indent=2))
        return 0

    stamp = args.archive_name or datetime.now(timezone.utc).strftime("legacy-%Y%m%dT%H%M%SZ")
    archive = queue / "archive" / stamp
    if archive.exists():
        parser.error(f"archive already exists: {archive}")
    archive.mkdir(parents=True, mode=0o700)
    os.chmod(archive.parent, 0o700)
    os.chmod(archive, 0o700)
    for path in (pending_path, decisions_path, review_path):
        if path.is_file():
            shutil.copy2(path, archive / path.name)
            os.chmod(archive / path.name, 0o600)
    if sidecars_dir.is_dir():
        shutil.copytree(sidecars_dir, archive / "sidecars", dirs_exist_ok=True)
        for path in (archive / "sidecars").rglob("*"):
            os.chmod(path, 0o700 if path.is_dir() else 0o600)

    retained = "# Dream review queue\n"
    if keep_ids:
        retained += "\n" + "\n".join(by_id[candidate_id] for candidate_id in sorted(keep_ids))
    atomic_text(pending_path, retained)

    decisions = load_json(decisions_path, {})
    decisions = decisions if isinstance(decisions, dict) else {}
    atomic_json(decisions_path, {key: value for key, value in decisions.items() if key in keep_ids})
    review = load_json(review_path, {})
    entries = review.get("entries", []) if isinstance(review, dict) else []
    entries = [entry for entry in entries if isinstance(entry, dict) and entry.get("id") in keep_ids]
    atomic_json(review_path, {"entries": entries})
    for candidate_id in orphan_sidecars:
        sidecar_paths[candidate_id].unlink(missing_ok=True)

    report["archive"] = str(archive)
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
