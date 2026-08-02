from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.sh"


class SetupTests(unittest.TestCase):
    def run_setup(self, codex_home: Path) -> subprocess.CompletedProcess[str]:
        self.assertTrue(SETUP.is_file(), f"missing required file: {SETUP}")
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        return subprocess.run(
            ["bash", str(SETUP)],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_installs_exact_source_symlink_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir) / "codex-home"
            target = codex_home / "skills" / "parallel-workstreams"

            first = self.run_setup(codex_home)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertTrue(target.is_symlink())
            self.assertEqual(target.resolve(), ROOT.resolve())

            second = self.run_setup(codex_home)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(target.resolve(), ROOT.resolve())

    def test_refuses_to_replace_a_different_existing_target(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir) / "codex-home"
            target = codex_home / "skills" / "parallel-workstreams"
            target.mkdir(parents=True)
            marker = target / "keep.txt"
            marker.write_text("preserve me\n")

            result = self.run_setup(codex_home)

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(target.is_dir())
            self.assertFalse(target.is_symlink())
            self.assertEqual(marker.read_text(), "preserve me\n")


if __name__ == "__main__":
    unittest.main()
