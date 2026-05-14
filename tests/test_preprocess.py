import importlib.util
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timezone
from io import StringIO
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PREPROCESS_PATH = REPO_ROOT / "skills" / "dream-skill" / "scripts" / "preprocess.py"


def load_preprocess():
    spec = importlib.util.spec_from_file_location("dream_preprocess", PREPROCESS_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_jsonl(path: Path, events: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(event) + "\n" for event in events),
        encoding="utf-8",
    )


class PreprocessConversationSourcesTest(unittest.TestCase):
    def setUp(self):
        self.preprocess = load_preprocess()
        self.now = datetime.now(timezone.utc).isoformat()

    def run_preprocess(self, argv: list[str]) -> tuple[int, str]:
        stderr = StringIO()
        with redirect_stderr(stderr):
            status = self.preprocess.main(argv)
        return status, stderr.getvalue()

    def test_combines_claude_and_codex_conversation_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            claude_root = tmp_path / "claude"
            codex_root = tmp_path / "codex"
            output = tmp_path / "sessions.md"

            write_jsonl(
                claude_root / "project" / "claude-session.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": self.now,
                        "message": {
                            "content": [
                                {"type": "text", "text": "What changed this week?"}
                            ]
                        },
                    },
                    {
                        "type": "user",
                        "timestamp": self.now,
                        "message": {
                            "content": [
                                {
                                    "type": "text",
                                    "text": "I am now focused on learning Rust.",
                                }
                            ]
                        },
                    },
                ],
            )
            write_jsonl(
                codex_root / "2026" / "05" / "13" / "rollout-test.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": self.now,
                        "payload": {
                            "id": "codex-session",
                            "timestamp": self.now,
                            "originator": "codex-tui",
                            "source": "cli",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "user_message",
                            "message": "I switched my current priority to AI evals.",
                            "images": [],
                            "local_images": [],
                            "text_elements": [],
                        },
                    },
                ],
            )

            status, stderr = self.run_preprocess(
                [
                    "--sessions-root",
                    str(claude_root),
                    "--codex-sessions-root",
                    str(codex_root),
                    "--sources",
                    "claude,codex",
                    "--since",
                    "7d",
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(status, 0, stderr)
            body = output.read_text(encoding="utf-8")
            self.assertIn("# Cleaned local conversation signals", body)
            self.assertIn("# Sources: Claude Code, Codex CLI", body)
            self.assertIn("--- claude session claude-session ---", body)
            self.assertIn("[★] USER: I am now focused on learning Rust.", body)
            self.assertIn("--- codex session rollout-test ---", body)
            self.assertIn(
                "[★] USER: I switched my current priority to AI evals.",
                body,
            )

    def test_codex_uses_event_messages_and_ignores_context_replay_and_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            codex_root = tmp_path / "codex"
            output = tmp_path / "codex.md"

            write_jsonl(
                codex_root / "2026" / "05" / "13" / "rollout-test.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": self.now,
                        "payload": {
                            "id": "codex-session",
                            "timestamp": self.now,
                            "originator": "codex-tui",
                            "source": "cli",
                        },
                    },
                    {
                        "type": "response_item",
                        "timestamp": self.now,
                        "payload": {
                            "type": "message",
                            "role": "user",
                            "content": [
                                {
                                    "type": "input_text",
                                    "text": "I moved to Mars in a replayed context.",
                                }
                            ],
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "user_message",
                            "message": "I am now using Codex CLI for dream cycles.",
                            "images": [],
                            "local_images": [],
                            "text_elements": [],
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "exec_command_end",
                            "aggregated_output": "I moved to Venus in tool output.",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "agent_message",
                            "message": "Which CLI is the new default?",
                            "phase": "final",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "user_message",
                            "message": "Codex",
                            "images": [],
                            "local_images": [],
                            "text_elements": [],
                        },
                    },
                ],
            )

            status, stderr = self.run_preprocess(
                [
                    "--sources",
                    "codex",
                    "--codex-sessions-root",
                    str(codex_root),
                    "--sessions-root",
                    str(tmp_path / "missing-claude"),
                    "--since",
                    "7d",
                    "--all",
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(status, 0, stderr)
            body = output.read_text(encoding="utf-8")
            self.assertIn("[★] USER: I am now using Codex CLI for dream cycles.", body)
            self.assertIn("ASST: Which CLI is the new default?", body)
            self.assertIn("[ ] USER: Codex", body)
            self.assertNotIn("Mars", body)
            self.assertNotIn("Venus", body)

    def test_missing_optional_codex_root_does_not_fail_claude_only_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            claude_root = tmp_path / "claude"
            output = tmp_path / "sessions.md"

            write_jsonl(
                claude_root / "claude-session.jsonl",
                [
                    {
                        "type": "user",
                        "timestamp": self.now,
                        "message": {
                            "content": [
                                {"type": "text", "text": "I changed my current focus."}
                            ]
                        },
                    },
                ],
            )

            status, stderr = self.run_preprocess(
                [
                    "--sessions-root",
                    str(claude_root),
                    "--codex-sessions-root",
                    str(tmp_path / "missing-codex"),
                    "--sources",
                    "claude,codex",
                    "--since",
                    "7d",
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(status, 0, stderr)
            self.assertIn("codex sessions root not found", stderr)
            body = output.read_text(encoding="utf-8")
            self.assertIn("[★] USER: I changed my current focus.", body)

    def test_filters_events_older_than_since_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            codex_root = tmp_path / "codex"
            output = tmp_path / "sessions.md"

            write_jsonl(
                codex_root / "rollout-test.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": self.now,
                        "payload": {
                            "id": "codex-session",
                            "timestamp": self.now,
                            "originator": "codex-tui",
                            "source": "cli",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2000-01-01T00:00:00Z",
                        "payload": {
                            "type": "user_message",
                            "message": "I changed my current focus in 2000.",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "user_message",
                            "message": "I changed my current focus today.",
                        },
                    },
                ],
            )

            status, stderr = self.run_preprocess(
                [
                    "--sources",
                    "codex",
                    "--codex-sessions-root",
                    str(codex_root),
                    "--since",
                    "7d",
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(status, 0, stderr)
            body = output.read_text(encoding="utf-8")
            self.assertIn("today", body)
            self.assertNotIn("2000", body)

    def test_codex_source_only_includes_cli_generated_sessions(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            codex_root = tmp_path / "codex"
            output = tmp_path / "sessions.md"

            write_jsonl(
                codex_root / "rollout-cli.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": self.now,
                        "payload": {
                            "id": "cli-session",
                            "timestamp": self.now,
                            "originator": "codex-tui",
                            "source": "cli",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "user_message",
                            "message": "I changed my current focus from the CLI.",
                        },
                    },
                ],
            )
            write_jsonl(
                codex_root / "rollout-desktop.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": self.now,
                        "payload": {
                            "id": "desktop-session",
                            "timestamp": self.now,
                            "originator": "Codex Desktop",
                            "source": "vscode",
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": self.now,
                        "payload": {
                            "type": "user_message",
                            "message": "I changed my current focus from desktop.",
                        },
                    },
                ],
            )

            status, stderr = self.run_preprocess(
                [
                    "--sources",
                    "codex",
                    "--codex-sessions-root",
                    str(codex_root),
                    "--since",
                    "7d",
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(status, 0, stderr)
            body = output.read_text(encoding="utf-8")
            self.assertIn("from the CLI", body)
            self.assertNotIn("desktop", body)
