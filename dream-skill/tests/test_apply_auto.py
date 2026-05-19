import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APPLY_AUTO_PATH = REPO_ROOT / "skills" / "dream-skill" / "scripts" / "apply_auto.py"


def load_apply_auto():
    spec = importlib.util.spec_from_file_location("dream_apply_auto", APPLY_AUTO_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ApplyAutoChannelDetectionTest(unittest.TestCase):
    def test_detects_claude_and_codex_as_labeled_conversation_channels(self):
        apply_auto = load_apply_auto()

        channels = apply_auto.count_channels(
            'Claude Session claude-session: "changed focus"; '
            'Codex Session rollout-2026-05-13T22-09: "changed focus"; '
            'Calendar: "Planning review" on 2026-05-13'
        )

        self.assertEqual(channels, ["calendar", "claude", "codex"])

    def test_preserves_legacy_session_channel_detection(self):
        apply_auto = load_apply_auto()

        channels = apply_auto.count_channels('Session 019e243e: "changed focus"')

        self.assertEqual(channels, ["sessions"])
