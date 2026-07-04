#!/usr/bin/env python3
"""Render a per-run clean-wiki report from an applied batch archive."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
from collections import Counter
from datetime import date
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
DEFAULT_CONFIG = SKILL_DIR / "config" / "vault-paths.toml"


def _load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def _batch_date(batch_id: str, generated_at: str | None = None) -> str:
    if len(batch_id) >= 8 and batch_id[:8].isdigit():
        return f"{batch_id[:4]}-{batch_id[4:6]}-{batch_id[6:8]}"
    if generated_at:
        return generated_at[:10]
    return date.today().isoformat()


def _run_slug(batch_id: str, report_date: str) -> str:
    match = re.match(r"^\d{8}T(\d{2})(\d{2})(\d{2})Z$", batch_id)
    if match:
        return f"{report_date}-{match.group(1)}{match.group(2)}{match.group(3)}"
    safe = re.sub(r"[^A-Za-z0-9]+", "-", batch_id).strip("-")
    return f"{report_date}-{safe}" if safe else report_date


def _run_label(batch_id: str, report_date: str) -> str:
    match = re.match(r"^\d{8}T(\d{2})(\d{2})(\d{2})Z$", batch_id)
    if match:
        return f"{report_date} {match.group(1)}:{match.group(2)}:{match.group(3)}Z"
    return report_date


def _load_config(config_path: Path) -> dict[str, Any]:
    if not config_path.exists():
        return {}
    with config_path.open("rb") as f:
        return tomllib.load(f)


def resolve_reports_dir(config_path: Path, override: Path | None = None) -> Path:
    if override is not None:
        return override.expanduser()

    env_override = os.environ.get("CLEAN_WIKI_REPORTS_DIR")
    if env_override:
        return Path(env_override).expanduser()

    cfg = _load_config(config_path)
    configured = cfg.get("reports_dir")
    if configured:
        return Path(configured).expanduser()

    vault_paths = [Path(v["path"]).expanduser() for v in cfg.get("vaults", []) if v.get("path")]
    if not vault_paths:
        return SKILL_DIR / "clean-reports"
    if len(vault_paths) == 1:
        return vault_paths[0].parent / "clean-reports"

    common = Path(os.path.commonpath([str(p) for p in vault_paths]))
    return common / "clean-reports"


def _wikilink(target: str) -> str:
    return f"[[{target.removesuffix('.md')}]]"


def _entry_target(entry: dict[str, Any]) -> str:
    return f"{entry.get('vault', '?')}/{entry.get('target_file', '?')}"


def _entry_line(entry: dict[str, Any]) -> str:
    verb = (entry.get("diff") or {}).get("verb") or entry.get("proposed_action", "change")
    target = _wikilink(_entry_target(entry))
    entry_id = entry.get("id", "?")
    signal = entry.get("signal_label") or entry.get("signal", "finding")
    return f"- `{entry_id}` {target} - {verb} ({signal})"


def _render_section(title: str, lines: list[str]) -> list[str]:
    rendered = [f"## {title}"]
    rendered.extend(lines or ["- None"])
    rendered.append("")
    return rendered


def render_report(applied_dir: Path) -> tuple[str, str]:
    apply_summary = _load_json(applied_dir / "apply-summary.json")
    queue = _load_json(applied_dir / "cleanup-queue.json")
    decisions = _load_json(applied_dir / "decisions.json")

    summary = apply_summary.get("summary", {})
    batch_id = summary.get("batch_id") or queue.get("batch_id") or applied_dir.name
    report_date = _batch_date(batch_id, queue.get("generated_at"))
    entries = {e.get("id"): e for e in queue.get("entries", [])}

    approved = [eid for eid, decision in decisions.items() if decision == "approve"]
    rejected = [eid for eid, decision in decisions.items() if decision == "reject"]
    deferred = [eid for eid, decision in decisions.items() if decision == "defer"]
    applied_ids = apply_summary.get("applied_ids", [])
    manual_items = apply_summary.get("manual", [])
    noop_items = apply_summary.get("noop", [])
    failures = apply_summary.get("failures", [])

    signal_counts = Counter(e.get("signal", "unknown") for e in queue.get("entries", []))
    vault_counts = Counter(e.get("vault", "unknown") for e in queue.get("entries", []))

    lines: list[str] = [
        "---",
        f"date: {report_date}",
        f"batch_id: {batch_id}",
        f"generated_at: {queue.get('generated_at', '')}",
        f"scan_version: {queue.get('scan_version', '')}",
        "---",
        "",
        f"# Clean run - {report_date}",
        "",
        "## Summary",
        f"- Batch: `{batch_id}`",
        f"- Findings reviewed: {len(queue.get('entries', []))}",
        f"- Approved: {summary.get('approved', len(approved))}",
        f"- Rejected: {summary.get('rejected', len(rejected))}",
        f"- Deferred: {summary.get('deferred', len(deferred))}",
        f"- Applied: {summary.get('applied', len(applied_ids))}",
        f"- Archived: {summary.get('archived', 0)}",
        f"- Manual / not auto-applied: {summary.get('manual', len(manual_items))}",
        f"- No-op: {summary.get('noop', len(noop_items))}",
        f"- Failures: {summary.get('failures', len(failures))}",
        "",
        "## Vaults",
    ]
    lines.extend(f"- `{vault}`: {count}" for vault, count in sorted(vault_counts.items()))
    lines.append("")
    lines.append("## Signals")
    lines.extend(f"- `{signal}`: {count}" for signal, count in sorted(signal_counts.items()))
    lines.append("")

    applied_lines = [_entry_line(entries[eid]) for eid in applied_ids if eid in entries]
    lines.extend(_render_section("Applied Changes", applied_lines))

    manual_lines = []
    for item in manual_items:
        entry = entries.get(item.get("id"))
        if entry:
            manual_lines.append(_entry_line(entry))
        else:
            manual_lines.append(f"- `{item.get('id', '?')}` {item.get('target', '?')} - {item.get('action', 'manual')}")
    lines.extend(_render_section("Manual / Not Auto-Applied", manual_lines))

    noop_lines = []
    for item in noop_items:
        entry = entries.get(item.get("id"))
        if entry:
            noop_lines.append(_entry_line(entry))
        else:
            noop_lines.append(f"- `{item.get('id', '?')}` {item.get('target', '?')} - {item.get('action', 'noop')}")
    lines.extend(_render_section("No-Ops", noop_lines))

    rejected_lines = [_entry_line(entries[eid]) for eid in rejected if eid in entries]
    lines.extend(_render_section("Rejected", rejected_lines))

    deferred_lines = [_entry_line(entries[eid]) for eid in deferred if eid in entries]
    lines.extend(_render_section("Deferred", deferred_lines))

    failure_lines = [
        f"- `{item.get('id', '?')}` {item.get('target', '?')} - {item.get('reason', 'failed')}"
        for item in failures
    ]
    lines.extend(_render_section("Failures", failure_lines))

    return report_date, "\n".join(lines).rstrip() + "\n"


def write_report(applied_dir: Path, config_path: Path = DEFAULT_CONFIG, reports_dir: Path | None = None) -> Path:
    applied_dir = applied_dir.resolve()
    report_date, content = render_report(applied_dir)
    destination_dir = resolve_reports_dir(config_path, reports_dir).resolve()
    destination_dir.mkdir(parents=True, exist_ok=True)

    apply_summary = _load_json(applied_dir / "apply-summary.json")
    summary = apply_summary.get("summary", {})
    batch_id = summary.get("batch_id") or applied_dir.name
    run_slug = _run_slug(batch_id, report_date)
    report_path = destination_dir / f"{run_slug}.md"
    report_path.write_text(content)

    index_path = destination_dir / "index.md"
    index_title = "# Clean runs index"
    link = f"[[{destination_dir.name}/{run_slug}]]"
    index_line = (
        f"- {_run_label(batch_id, report_date)} | {summary.get('applied', 0)} applied · "
        f"{summary.get('manual', 0)} manual · {summary.get('failures', 0)} failed → {link}"
    )

    existing = index_path.read_text().splitlines() if index_path.exists() else [index_title, ""]
    existing = [line for line in existing if link not in line]
    if not existing:
        existing = [index_title, ""]
    if existing[0] != index_title:
        existing = [index_title, ""] + existing
    existing.append(index_line)
    index_path.write_text("\n".join(existing).rstrip() + "\n")
    return report_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--applied-dir", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--reports-dir", type=Path, default=None)
    args = parser.parse_args(argv)

    report_path = write_report(args.applied_dir, args.config, args.reports_dir)
    print(report_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
