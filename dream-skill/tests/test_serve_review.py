"""Unit checks for the standard-library Dream review server helpers."""

from __future__ import annotations

import importlib.util
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SERVE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "serve-review.py"
spec = importlib.util.spec_from_file_location("dream_serve_review", SERVE_PATH)
serve = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(serve)


class ReviewServerHelpersTest(unittest.TestCase):
    def test_loopback_server_bind_does_not_resolve_dns(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            handler = serve.make_handler(
                root / "queue.json",
                root / "decisions.json",
                root / "review.html",
                "test-token",
                root / "feedback.json",
            )
            with patch("socket.getfqdn", side_effect=AssertionError("reverse DNS called")):
                server = serve.LoopbackThreadingHTTPServer(("127.0.0.1", 0), handler)
            try:
                self.assertEqual(server.server_name, "localhost")
                self.assertGreater(server.server_port, 0)
            finally:
                server.server_close()

    def test_host_parser_keeps_loopback_forms(self) -> None:
        self.assertEqual(serve.host_name("localhost:5174"), "localhost")
        self.assertEqual(serve.host_name("127.0.0.1:5174"), "127.0.0.1")
        self.assertEqual(serve.host_name("[::1]:5174"), "[::1]")

    def test_feedback_reason_contract(self) -> None:
        self.assertEqual(
            serve.DEFAULT_REASON,
            {"approve": "accepted", "defer": "review_later", "reject": "unspecified"},
        )
        self.assertIn("not_durable", serve.REASONS["reject"])
        self.assertIn("wrong_target", serve.REASONS["reject"])
        self.assertEqual(serve.REASONS["approve"], {"accepted"})

    def test_save_json_is_private_and_atomic(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            target = Path(raw_tmp) / "queue" / "review-feedback.json"
            serve.save_json(target, {"c-1": {"decision": "reject", "reason": "stale"}})
            self.assertEqual(
                json.loads(target.read_text()),
                {"c-1": {"decision": "reject", "reason": "stale"}},
            )
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)


if __name__ == "__main__":
    unittest.main()
