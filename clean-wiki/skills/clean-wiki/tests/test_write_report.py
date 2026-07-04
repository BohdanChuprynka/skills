from __future__ import annotations

import importlib.util
import json
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "write_report.py"
spec = importlib.util.spec_from_file_location("clean_wiki_write_report", SCRIPT_PATH)
write_report = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(write_report)


def _write_batch(applied_dir: Path, batch_id: str = "20260704T104813Z") -> None:
    applied_dir.mkdir(parents=True)
    (applied_dir / "apply-summary.json").write_text(
        json.dumps(
            {
                "summary": {
                    "batch_id": batch_id,
                    "approved": 4,
                    "applied": 2,
                    "manual": 1,
                    "noop": 1,
                    "failures": 0,
                    "archived": 1,
                    "rejected": 1,
                    "deferred": 0,
                },
                "manual": [
                    {
                        "id": "2026-07-04-003",
                        "action": "manual",
                        "target": "/tmp/vault/projects/wiki/index.md",
                    }
                ],
                "noop": [
                    {
                        "id": "2026-07-04-004",
                        "action": "fix-frontmatter",
                        "target": "/tmp/vault/setup/wiki/index.md",
                    }
                ],
                "failures": [],
                "applied_ids": ["2026-07-04-001", "2026-07-04-002"],
            }
        )
    )
    (applied_dir / "cleanup-queue.json").write_text(
        json.dumps(
            {
                "generated_at": "2026-07-04T10:38:40Z",
                "scan_version": "2.0",
                "entries": [
                    {
                        "id": "2026-07-04-001",
                        "signal": "stale_fact",
                        "signal_label": "stale fact",
                        "confidence": "high",
                        "category": "judgment",
                        "vault": "me",
                        "target_file": "wiki/Bio.md",
                        "target_line": 3,
                        "proposed_action": "edit-text",
                        "action_payload": {
                            "source_file": "wiki/Bio.md",
                            "snippet": "old bio",
                            "suggested_replacement": "new bio",
                            "why": "Bio was stale.",
                        },
                        "diff": {"verb": "EDIT TEXT", "before": "old bio", "after": "new bio"},
                        "context": "old bio",
                        "deferred_count": 0,
                        "first_seen": "2026-07-04",
                        "flagged_by": "subagent:me",
                        "decided": True,
                        "decision": "approve",
                        "decided_at": "2026-07-04T10:45:00Z",
                    },
                    {
                        "id": "2026-07-04-002",
                        "signal": "orphan",
                        "signal_label": "orphan page",
                        "confidence": "medium",
                        "category": "judgment",
                        "vault": "gym-sprint",
                        "target_file": "Welcome.md",
                        "target_line": None,
                        "proposed_action": "archive",
                        "action_payload": {
                            "source_file": "Welcome.md",
                            "snippet": "# Welcome",
                            "suggested_replacement": "",
                            "why": "Template page is orphaned.",
                        },
                        "diff": {"verb": "ARCHIVE PAGE", "target": "Welcome.md"},
                        "context": "# Welcome",
                        "deferred_count": 0,
                        "first_seen": "2026-07-04",
                        "flagged_by": "subagent:gym-sprint",
                        "decided": True,
                        "decision": "approve",
                        "decided_at": "2026-07-04T10:45:00Z",
                    },
                    {
                        "id": "2026-07-04-003",
                        "signal": "index_drift",
                        "signal_label": "index drift",
                        "confidence": "high",
                        "category": "auto",
                        "vault": "projects",
                        "target_file": "wiki/index.md",
                        "target_line": 20,
                        "proposed_action": "manual",
                        "action_payload": {
                            "source_file": "wiki/index.md",
                            "snippet": "dead link",
                            "suggested_replacement": "",
                            "why": "Needs human routing.",
                        },
                        "diff": {"verb": "MANUAL REVIEW", "target": "dead link"},
                        "context": "dead link",
                        "deferred_count": 0,
                        "first_seen": "2026-07-04",
                        "flagged_by": "subagent:projects",
                        "decided": True,
                        "decision": "approve",
                        "decided_at": "2026-07-04T10:45:00Z",
                    },
                    {
                        "id": "2026-07-04-005",
                        "signal": "broken_wikilink",
                        "signal_label": "broken wikilink",
                        "confidence": "high",
                        "category": "auto",
                        "vault": "me",
                        "target_file": "wiki/College.md",
                        "target_line": 9,
                        "proposed_action": "remove-link",
                        "action_payload": {
                            "source_file": "wiki/College.md",
                            "snippet": "[[missing]]",
                            "suggested_replacement": "",
                            "why": "Broken link.",
                        },
                        "diff": {"verb": "REMOVE LINK", "target": "[[missing]]"},
                        "context": "[[missing]]",
                        "deferred_count": 0,
                        "first_seen": "2026-07-04",
                        "flagged_by": "subagent:me",
                        "decided": True,
                        "decision": "reject",
                        "decided_at": "2026-07-04T10:45:00Z",
                    },
                ],
            }
        )
    )
    (applied_dir / "decisions.json").write_text(
        json.dumps(
            {
                "2026-07-04-001": "approve",
                "2026-07-04-002": "approve",
                "2026-07-04-003": "approve",
                "2026-07-04-004": "approve",
                "2026-07-04-005": "reject",
            }
        )
    )


def test_write_report_uses_common_vault_parent_by_default(tmp_path: Path) -> None:
    config = tmp_path / "vault-paths.toml"
    config.write_text(
        f"""
[[vaults]]
name = "me"
path = "{tmp_path}/Obsidian/me"

[[vaults]]
name = "projects"
path = "{tmp_path}/Obsidian/projects"
"""
    )
    applied_dir = tmp_path / "data" / "applied" / "20260704T104813Z"
    _write_batch(applied_dir)

    report_path = write_report.write_report(applied_dir, config)

    assert report_path == tmp_path / "Obsidian" / "clean-reports" / "2026-07-04-104813.md"
    text = report_path.read_text()
    assert "# Clean run - 2026-07-04" in text
    assert "batch_id: 20260704T104813Z" in text
    assert "- Approved: 4" in text
    assert "- Applied: 2" in text
    assert "## Applied Changes" in text
    assert "[[me/wiki/Bio]]" in text
    assert "ARCHIVE PAGE" in text
    assert "## Manual / Not Auto-Applied" in text
    assert "2026-07-04-003" in text

    index = report_path.parent / "index.md"
    assert "- 2026-07-04 10:48:13Z | 2 applied · 1 manual · 0 failed → [[clean-reports/2026-07-04-104813]]" in index.read_text()


def test_write_report_is_idempotent_for_index(tmp_path: Path) -> None:
    config = tmp_path / "vault-paths.toml"
    reports = tmp_path / "reports"
    config.write_text(
        f"""
reports_dir = "{reports}"

[[vaults]]
name = "me"
path = "{tmp_path}/Obsidian/me"
"""
    )
    applied_dir = tmp_path / "data" / "applied" / "20260704T104813Z"
    _write_batch(applied_dir)

    first = write_report.write_report(applied_dir, config)
    second = write_report.write_report(applied_dir, config)

    assert first == second == reports / "2026-07-04-104813.md"
    index_lines = (reports / "index.md").read_text().splitlines()
    assert index_lines.count("- 2026-07-04 10:48:13Z | 2 applied · 1 manual · 0 failed → [[reports/2026-07-04-104813]]") == 1


def test_write_report_keeps_same_day_batches_separate(tmp_path: Path) -> None:
    config = tmp_path / "vault-paths.toml"
    reports = tmp_path / "reports"
    config.write_text(
        f"""
reports_dir = "{reports}"

[[vaults]]
name = "me"
path = "{tmp_path}/Obsidian/me"
"""
    )
    first_dir = tmp_path / "data" / "applied" / "20260704T104813Z"
    second_dir = tmp_path / "data" / "applied" / "20260704T112233Z"
    _write_batch(first_dir, "20260704T104813Z")
    _write_batch(second_dir, "20260704T112233Z")

    first = write_report.write_report(first_dir, config)
    second = write_report.write_report(second_dir, config)

    assert first == reports / "2026-07-04-104813.md"
    assert second == reports / "2026-07-04-112233.md"
    assert first.read_text() != second.read_text()
    index = (reports / "index.md").read_text()
    assert "[[reports/2026-07-04-104813]]" in index
    assert "[[reports/2026-07-04-112233]]" in index
