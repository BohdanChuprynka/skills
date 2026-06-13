"""Security + persistence tests for the clean-wiki review server."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

SERVE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "serve.py"
spec = importlib.util.spec_from_file_location("clean_wiki_serve", SERVE_PATH)
serve = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(serve)


def _app(tmp_path: Path, token: str = "secret-token"):
    return serve.make_app(Path("unused-config.toml"), tmp_path, token)


def test_api_decide_requires_token(tmp_path: Path) -> None:
    client = _app(tmp_path).test_client()
    payload = {"id": "abc", "decision": "approve"}

    assert client.post("/api/decide", json=payload).status_code == 403
    assert (
        client.post(
            "/api/decide", json=payload, headers={"X-CSRF-Token": "wrong"}
        ).status_code
        == 403
    )
    ok = client.post("/api/decide", json=payload, headers={"X-CSRF-Token": "secret-token"})
    assert ok.status_code == 200


def test_api_rejects_non_loopback_host(tmp_path: Path) -> None:
    """DNS-rebinding defense: a request whose Host header is not loopback is refused."""
    client = _app(tmp_path).test_client()
    r = client.get(
        "/api/queue",
        headers={"X-CSRF-Token": "secret-token"},
        environ_overrides={"HTTP_HOST": "attacker.example"},
    )
    assert r.status_code == 403


def test_decisions_persist_and_accumulate(tmp_path: Path) -> None:
    client = _app(tmp_path).test_client()
    h = {"X-CSRF-Token": "secret-token"}
    client.post("/api/decide", json={"id": "a", "decision": "approve"}, headers=h)
    client.post("/api/decide", json={"id": "b", "decision": "reject"}, headers=h)
    saved = json.loads((tmp_path / "decisions.json").read_text())
    assert saved == {"a": "approve", "b": "reject"}
