import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from voice_check import corpus, profile

ROOT = Path(__file__).resolve().parents[1]


def _write_profile(tmp: Path) -> Path:
    recs = [
        corpus.Record("i", "p", "Quick note. It works. Ping me if it breaks.", "polished_writing", None, {}),
        corpus.Record("j", "p", "Short and direct. No fluff. Ship it.", "polished_writing", None, {}),
    ]
    out = tmp / "profiles"
    profile.write_profile(profile.build_profile(recs), out)
    return out


class CheckCliTests(unittest.TestCase):
    def test_check_draft_stdin_json(self):
        tmp = Path(tempfile.mkdtemp())
        prof = _write_profile(tmp)
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "check_draft.py"),
             "--profile", str(prof), "--format", "json"],
            input="We will leverage synergy — really.",
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("score", payload)

    def test_strict_flag_fails_low_score(self):
        tmp = Path(tempfile.mkdtemp())
        prof = _write_profile(tmp)
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "check_draft.py"),
             "--profile", str(prof), "--strict", "--min-score", "70"],
            input="Furthermore, we leverage robust holistic synergies — moreover, utilize paradigms.",
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)

    def test_rewrite_flag_outputs_baseline(self):
        tmp = Path(tempfile.mkdtemp())
        prof = _write_profile(tmp)
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "check_draft.py"),
             "--profile", str(prof), "--rewrite"],
            input="We will utilize this — basically.",
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("—", result.stdout.split("SUGGESTED REWRITE")[-1])


if __name__ == "__main__":
    unittest.main()
