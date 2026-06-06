import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ProfileCliTests(unittest.TestCase):
    def test_profile_corpus_writes_artifacts(self):
        d = Path(tempfile.mkdtemp())
        writing = d / "input" / "writing"
        writing.mkdir(parents=True)
        (writing / "a.md").write_text("Quick note. It works. Ping me if it breaks.")
        out = d / "profiles"
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "profile_corpus.py"),
             "--input", str(d / "input"), "--out", str(out)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((out / "voice_rules.json").exists())
        self.assertTrue((out / "voice_profile.md").exists())
        self.assertTrue((out / "profile_stats.json").exists())

    def test_empty_input_exits_nonzero(self):
        d = Path(tempfile.mkdtemp())
        (d / "input").mkdir()
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "profile_corpus.py"),
             "--input", str(d / "input"), "--out", str(d / "profiles")],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
