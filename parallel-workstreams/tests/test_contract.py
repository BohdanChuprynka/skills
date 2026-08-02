from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "SKILL.md"
CONTRACTS = ROOT / "references" / "contracts.md"
METADATA = ROOT / "agents" / "openai.yaml"
SCENARIOS = ROOT / "tests" / "scenarios.md"


def parse_frontmatter(text: str) -> dict[str, str]:
    match = re.match(r"\A---\n(?P<body>.*?)\n---\n", text, re.DOTALL)
    if not match:
        return {}
    fields: dict[str, str] = {}
    for raw_line in match.group("body").splitlines():
        key, separator, value = raw_line.partition(":")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


class SkillContractTests(unittest.TestCase):
    def test_required_package_files_exist(self) -> None:
        for path in (SKILL, CONTRACTS, METADATA, SCENARIOS):
            with self.subTest(path=path):
                self.assertTrue(path.is_file(), f"missing required file: {path}")

    def test_frontmatter_is_discoverable_and_minimal(self) -> None:
        self.assertTrue(SKILL.is_file(), f"missing required file: {SKILL}")
        fields = parse_frontmatter(SKILL.read_text())
        self.assertEqual(set(fields), {"name", "description"})
        self.assertEqual(fields["name"], "parallel-workstreams")
        self.assertTrue(fields["description"].startswith("Use when "))
        self.assertIn("visible", fields["description"])
        self.assertIn("parallel", fields["description"])

    def test_runtime_skill_is_concise_and_enforces_core_gate(self) -> None:
        self.assertTrue(SKILL.is_file(), f"missing required file: {SKILL}")
        skill = SKILL.read_text()
        self.assertLessEqual(len(skill.split()), 500)
        for required in (
            "Create no peer task before approval.",
            "Do not use subagents as a silent fallback.",
            "Pin every ready task immediately.",
            "references/contracts.md",
        ):
            with self.subTest(required=required):
                self.assertIn(required, skill)

    def test_operational_contract_names_current_task_controls(self) -> None:
        self.assertTrue(CONTRACTS.is_file(), f"missing required file: {CONTRACTS}")
        contracts = CONTRACTS.read_text()
        for required in (
            "list_projects",
            "create_thread",
            "list_threads",
            "set_thread_title",
            "set_thread_pinned",
            "wait_threads",
            "read_thread",
            "send_message_to_thread",
            "clientThreadId",
            "gpt-5.6-sol",
            "gpt-5.6-luna",
            "Do not push",
        ):
            with self.subTest(required=required):
                self.assertIn(required, contracts)

    def test_contract_covers_grouping_testing_and_retention(self) -> None:
        self.assertTrue(CONTRACTS.is_file(), f"missing required file: {CONTRACTS}")
        contracts = CONTRACTS.read_text().lower()
        for required in (
            "file overlap",
            "focused tests",
            "full verification",
            "dependency order",
            "never unpin",
            "working-tree",
            "base sha",
        ):
            with self.subTest(required=required):
                self.assertIn(required, contracts)

    def test_ui_metadata_matches_skill(self) -> None:
        self.assertTrue(METADATA.is_file(), f"missing required file: {METADATA}")
        self.assertEqual(
            METADATA.read_text(),
            "interface:\n"
            "  display_name: \"Parallel Workstreams\"\n"
            "  short_description: \"Coordinate visible Codex tasks in parallel\"\n"
            "  default_prompt: \"Use $parallel-workstreams to coordinate this work through visible Codex tasks.\"\n",
        )

    def test_scenario_fixture_covers_required_pressure_cases(self) -> None:
        scenarios = SCENARIOS.read_text()
        for heading in (
            "Scenario A: Plan-only boundary",
            "Scenario B: Central-plan implementation wave",
            "Scenario C: Conflicting and external work",
            "Scenario D: Topology change",
            "Scenario E: Asynchronous worktree readiness",
        ):
            with self.subTest(heading=heading):
                self.assertIn(heading, scenarios)


if __name__ == "__main__":
    unittest.main()
