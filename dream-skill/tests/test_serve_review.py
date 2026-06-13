"""Security + persistence tests for the dream-skill review server.

Run manually: PYTHONPATH=scripts python3 -m pytest tests/test_serve_review.py
(The shell run-all.sh harness does not collect Python tests.)
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

SERVE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "serve-review.py"
spec = importlib.util.spec_from_file_location("dream_serve_review", SERVE_PATH)
serve = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(serve)


def _app(tmp_path: Path, token: str = "secret-token"):
    return serve.make_app(
        tmp_path / "review-input.json",
        tmp_path / "review-decisions.json",
        tmp_path / "web",
        token,
    )


def test_api_decide_requires_token(tmp_path: Path) -> None:
    client = _app(tmp_path).test_client()
    payload = {"id": "abc", "decision": "approve"}
    assert client.post("/api/decide", json=payload).status_code == 403
    assert (
        client.post("/api/decide", json=payload, headers={"X-CSRF-Token": "no"}).status_code
        == 403
    )
    assert (
        client.post(
            "/api/decide", json=payload, headers={"X-CSRF-Token": "secret-token"}
        ).status_code
        == 200
    )


def test_api_rejects_non_loopback_host(tmp_path: Path) -> None:
    client = _app(tmp_path).test_client()
    r = client.get(
        "/api/queue",
        headers={"X-CSRF-Token": "secret-token"},
        environ_overrides={"HTTP_HOST": "attacker.example"},
    )
    assert r.status_code == 403


def test_decisions_persist(tmp_path: Path) -> None:
    client = _app(tmp_path).test_client()
    h = {"X-CSRF-Token": "secret-token"}
    client.post("/api/decide", json={"id": "a", "decision": "approve"}, headers=h)
    client.post("/api/decide", json={"id": "b", "decision": "reject"}, headers=h)
    saved = json.loads((tmp_path / "review-decisions.json").read_text())
    assert saved == {"a": "approve", "b": "reject"}
