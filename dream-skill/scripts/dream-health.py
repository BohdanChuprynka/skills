#!/usr/bin/env python3
"""Report content-free Dream runtime health and queue integrity."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


PENDING_ID_RE = re.compile(r"^\*\*ID:\*\*\s*(\S+)\s*$", re.MULTILINE)


def load_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def marker_info(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"path": str(path), "present": path.is_file()}
    if not path.is_file():
        return result
    raw = path.read_text(encoding="utf-8", errors="ignore").strip()
    result["value"] = raw
    try:
        if raw.isdigit():
            marker_date = datetime.fromtimestamp(int(raw), timezone.utc).date()
            result["timestamp"] = datetime.fromtimestamp(int(raw), timezone.utc).isoformat().replace("+00:00", "Z")
        else:
            marker_date = date.fromisoformat(raw)
        result["age_days"] = (date.today() - marker_date).days
        result["valid"] = True
    except (ValueError, OverflowError, OSError):
        result["valid"] = False
    return result


def collect_states(runs_dir: Path) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}
    paths = list(runs_dir.glob("*.json")) + list(runs_dir.glob("*/state.json"))
    for path in paths:
        state_value = load_json(path)
        if not isinstance(state_value, dict) or not state_value.get("run_id"):
            continue
        run_id = str(state_value["run_id"])
        state_value["state_path"] = str(path)
        previous = by_id.get(run_id)
        if previous is None or str(state_value.get("updated_at", "")) >= str(previous.get("updated_at", "")):
            by_id[run_id] = state_value
    return sorted(by_id.values(), key=lambda item: str(item.get("updated_at", "")), reverse=True)


def latest_metric(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    latest = None
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            latest = value
    return latest


def storage_bytes(root: Path) -> int:
    total = 0
    if not root.exists():
        return total
    for path in root.rglob("*"):
        try:
            if path.is_file() and not path.is_symlink():
                total += path.stat().st_size
        except OSError:
            pass
    return total


def insecure_paths(root: Path, fix: bool) -> list[str]:
    insecure: list[str] = []
    if not root.exists():
        return insecure
    for path in [root, *root.rglob("*")]:
        if path.is_symlink():
            continue
        try:
            mode = stat.S_IMODE(path.stat().st_mode)
        except OSError:
            continue
        expected = 0o700 if path.is_dir() else 0o600
        if mode & 0o077:
            insecure.append(str(path))
            if fix:
                os.chmod(path, expected)
    return insecure


def collect(home: Path, fix_permissions: bool) -> dict[str, Any]:
    queue_dir = home / "queue"
    pending_path = queue_dir / "pending.md"
    pending_text = pending_path.read_text(encoding="utf-8", errors="ignore") if pending_path.is_file() else ""
    pending_ids = PENDING_ID_RE.findall(pending_text)
    sidecar_ids = {path.stem for path in (queue_dir / "sidecars").glob("*.json")}
    decisions = load_json(queue_dir / "review-decisions.json", {})
    decision_ids = set(decisions) if isinstance(decisions, dict) else set()
    states = collect_states(home / "runs")
    latest = states[0] if states else None
    failed = [state for state in states if state.get("status") == "failed"]
    active = [state for state in states if state.get("status") in {"running", "ready-to-advance"}]
    permissions = insecure_paths(home, fix_permissions)

    alerts: list[str] = []
    markers = {
        "claude": marker_info(home / "last-run"),
        "codex": marker_info(home / "last-run-codex"),
    }
    shadow_markers = {
        "claude": marker_info(home / "shadow-markers/last-run"),
        "codex": marker_info(home / "shadow-markers/last-run-codex"),
    }
    for source, marker in markers.items():
        if not marker.get("present"):
            alerts.append(f"missing {source} marker")
        elif not marker.get("valid"):
            alerts.append(f"invalid {source} marker")
        elif int(marker.get("age_days", 0)) > 14:
            alerts.append(f"stale {source} marker: {marker['age_days']} days")
    orphan_pending = sorted(set(pending_ids) - sidecar_ids)
    orphan_sidecars = sorted(sidecar_ids - set(pending_ids))
    if orphan_pending:
        alerts.append(f"{len(orphan_pending)} pending entries lack sidecars")
    if orphan_sidecars:
        alerts.append(f"{len(orphan_sidecars)} sidecars lack pending entries")
    if failed:
        alerts.append(f"{len(failed)} failed run(s) retained")
    if active:
        alerts.append(f"{len(active)} run(s) not finalized")
    if permissions:
        verb = "fixed" if fix_permissions else "found"
        alerts.append(f"{verb} {len(permissions)} paths with group/other permissions")

    routing_gaps = home / "routing-gaps.log"
    errors = home / "error.log"
    failures = home / "metrics/failures.jsonl"
    result = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "home": str(home),
        "markers": markers,
        "shadow_markers": shadow_markers,
        "runs": {
            "known": len(states),
            "failed": len(failed),
            "active": len(active),
            "latest": {
                key: latest.get(key)
                for key in ("run_id", "status", "mode", "updated_at", "source", "window")
                if latest and key in latest
            } if latest else None,
        },
        "queue": {
            "pending_entries": len(pending_ids),
            "sidecars": len(sidecar_ids),
            "review_decisions": len(decision_ids),
            "orphan_pending": len(orphan_pending),
            "orphan_sidecars": len(orphan_sidecars),
        },
        "logs": {
            "routing_gap_lines": sum(1 for _ in routing_gaps.open(errors="ignore")) if routing_gaps.is_file() else 0,
            "error_lines": sum(1 for _ in errors.open(errors="ignore")) if errors.is_file() else 0,
            "failure_events": sum(1 for _ in failures.open(errors="ignore")) if failures.is_file() else 0,
            "latest_metric": latest_metric(home / "metrics/runs.jsonl"),
            "gap_run_files": len(list((home / "gaps").glob("*.json"))),
            "latest_run_gaps": (
                len((load_json(home / "gaps" / f"{latest['run_id']}.json", {}) or {}).get("gaps", []))
                if latest else 0
            ),
        },
        "storage_bytes": storage_bytes(home),
        "privacy": {"unsafe_paths": len(permissions), "fixed": fix_permissions},
        "alerts": alerts,
    }
    return result


def human(result: dict[str, Any]) -> str:
    runs = result["runs"]
    queue = result["queue"]
    lines = [
        f"Dream health: {len(result['alerts'])} alert(s)",
        f"Runs: {runs['known']} known, {runs['failed']} failed, {runs['active']} active",
        f"Queue: {queue['pending_entries']} pending, {queue['sidecars']} sidecars, {queue['orphan_pending']} orphan pending",
        f"Storage: {result['storage_bytes'] / 1_048_576:.1f} MiB",
    ]
    latest = runs.get("latest")
    if latest:
        lines.append(f"Latest: {latest.get('run_id')} [{latest.get('status')}]")
    lines.extend(f"ALERT: {alert}" for alert in result["alerts"])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home() / ".claude/dream-skill")
    parser.add_argument("--human", action="store_true")
    parser.add_argument("--fix-permissions", action="store_true")
    parser.add_argument("--strict", action="store_true", help="exit 1 when alerts remain")
    args = parser.parse_args()
    result = collect(args.home.expanduser().resolve(), args.fix_permissions)
    print(human(result) if args.human else json.dumps(result, indent=2, ensure_ascii=False))
    return 1 if args.strict and result["alerts"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
