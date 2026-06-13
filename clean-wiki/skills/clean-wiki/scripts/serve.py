#!/usr/bin/env python3
"""
clean-wiki / serve.py

Flask app serving the Tinder-swipe review UI at http://localhost:5173.

Read-only review server. Reads data/cleanup-queue.json (written by Claude
before launching this server). Captures decisions to data/decisions.json
(incremental, resumable). Shuts itself down on /api/shutdown so the
orchestrating Claude knows the user is done.

Apply, scan, and vault selection no longer live here — Claude does those.

Usage:
    python serve.py [--config CONFIG] [--data-dir DATA] [--port PORT] [--no-browser]
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import signal
import sys
import threading
import tomllib
import webbrowser
from pathlib import Path
from threading import Timer

from flask import Flask, jsonify, request, send_from_directory


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
WEB_DIR = SKILL_DIR / "web"
DEFAULT_CONFIG = SKILL_DIR / "config" / "vault-paths.toml"
DEFAULT_DATA_DIR = SKILL_DIR / "data"

# Flask's dev server is threaded, and decisions.json is read-modify-written on
# every swipe; serialize those so concurrent handlers can't drop/clobber writes.
_decisions_lock = threading.Lock()
_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}


def load_config(path: Path) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def load_decisions(p: Path) -> dict:
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        return {}


def save_decisions(p: Path, d: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    # Atomic write: a reader during a plain write_text can observe a truncated
    # file and load_decisions would silently reset it to {}.
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(d, indent=2))
    os.replace(tmp, p)


def make_app(config_path: Path, data_dir: Path, token: str) -> Flask:
    app = Flask(__name__, static_folder=str(WEB_DIR), static_url_path="")
    app.config["CLEANWIKI_TOKEN"] = token

    queue_path = data_dir / "cleanup-queue.json"
    decisions_path = data_dir / "decisions.json"

    @app.before_request
    def _guard_api():
        # Only the data API needs guarding; the static shell is harmless.
        if not request.path.startswith("/api/"):
            return None
        # DNS-rebinding defense: the Host header must resolve to loopback. A
        # rebinding page that points a hostname at 127.0.0.1 would otherwise be
        # same-origin with this server and could read vault content.
        host = (request.host or "").rsplit(":", 1)[0]
        if host not in _LOOPBACK_HOSTS:
            return jsonify({"error": "invalid host"}), 403
        # CSRF defense: require the per-run token. It is not a cookie, so a
        # cross-site page cannot have it auto-attached and cannot read it.
        supplied = request.headers.get("X-CSRF-Token") or request.args.get("token", "")
        # .encode() both sides: compare_digest raises TypeError on non-ASCII str,
        # which would surface as a 500 instead of a clean 403.
        if not supplied or not secrets.compare_digest(
            supplied.encode("utf-8"), app.config["CLEANWIKI_TOKEN"].encode("utf-8")
        ):
            return jsonify({"error": "forbidden"}), 403
        return None

    @app.route("/")
    def index():
        if not WEB_DIR.exists() or not (WEB_DIR / "index.html").exists():
            return "web/index.html missing — UI not deployed", 500
        return send_from_directory(WEB_DIR, "index.html")

    @app.get("/api/queue")
    def api_queue():
        if not queue_path.exists():
            return jsonify({"error": "no cleanup-queue.json — run /clean-wiki in Claude first"}), 404
        try:
            q = json.loads(queue_path.read_text())
        except json.JSONDecodeError:
            return jsonify({"error": "cleanup-queue.json is not valid JSON"}), 500
        decisions = load_decisions(decisions_path)
        for e in q.get("entries", []):
            eid = e.get("id")
            if eid is not None and eid in decisions:
                e["decided"] = True
                e["decision"] = decisions[eid]
        return jsonify(q)

    @app.post("/api/decide")
    def api_decide():
        body = request.get_json(silent=True) or {}
        entry_id = body.get("id")
        decision = body.get("decision")
        if not entry_id or decision not in ("approve", "reject", "defer"):
            return jsonify({"error": "id + decision (approve|reject|defer) required"}), 400
        with _decisions_lock:
            decisions = load_decisions(decisions_path)
            decisions[entry_id] = decision
            save_decisions(decisions_path, decisions)
            total = len(decisions)
        return jsonify({"ok": True, "saved": {entry_id: decision}, "total": total})

    @app.post("/api/batch-decide")
    def api_batch_decide():
        body = request.get_json(silent=True) or {}
        incoming = body.get("decisions", {})
        if not isinstance(incoming, dict):
            return jsonify({"error": "decisions must be an object"}), 400
        with _decisions_lock:
            decisions = load_decisions(decisions_path)
            added = 0
            for entry_id, decision in incoming.items():
                if decision not in ("approve", "reject", "defer"):
                    continue
                decisions[entry_id] = decision
                added += 1
            save_decisions(decisions_path, decisions)
            total = len(decisions)
        return jsonify({"ok": True, "saved": added, "total": total})

    @app.get("/api/decisions")
    def api_decisions():
        return jsonify(load_decisions(decisions_path))

    @app.post("/api/shutdown")
    def api_shutdown():
        """Signal the orchestrating Claude that the user is done."""
        # Werkzeug dev-server shutdown was removed in newer versions, so fall
        # back to sending SIGTERM to our own process.
        def _die():
            os.kill(os.getpid(), signal.SIGTERM)
        Timer(0.3, _die).start()
        return jsonify({"ok": True})

    return app


def open_browser_after(url: str, delay: float = 0.8) -> None:
    Timer(delay, lambda: webbrowser.open(url)).start()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    if not args.config.exists():
        print(f"error: config not found: {args.config}", file=sys.stderr)
        return 1

    cfg = load_config(args.config)
    ui_cfg = cfg.get("ui", {})
    port = args.port or ui_cfg.get("port", 5173)
    auto_open = ui_cfg.get("auto_open_browser", True) and not args.no_browser

    # Per-run CSRF token. The UI reads it from the URL and echoes it on every
    # /api/* call; without it the data API rejects the request.
    token = secrets.token_urlsafe(32)
    app = make_app(args.config, args.data_dir, token)
    url = f"http://localhost:{port}/?token={token}"
    print(f"clean-wiki review UI → {url}")
    print("  (open the URL above — the token gates the review API)")
    if auto_open:
        open_browser_after(url)
    app.run(host="127.0.0.1", port=port, debug=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
