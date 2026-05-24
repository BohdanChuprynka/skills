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
import signal
import sys
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
    p.write_text(json.dumps(d, indent=2))


def make_app(config_path: Path, data_dir: Path) -> Flask:
    app = Flask(__name__, static_folder=str(WEB_DIR), static_url_path="")

    queue_path = data_dir / "cleanup-queue.json"
    decisions_path = data_dir / "decisions.json"

    @app.route("/")
    def index():
        if not WEB_DIR.exists() or not (WEB_DIR / "index.html").exists():
            return "web/index.html missing — UI not deployed", 500
        return send_from_directory(WEB_DIR, "index.html")

    @app.get("/api/queue")
    def api_queue():
        if not queue_path.exists():
            return jsonify({"error": "no cleanup-queue.json — run /clean-wiki in Claude first"}), 404
        q = json.loads(queue_path.read_text())
        decisions = load_decisions(decisions_path)
        for e in q.get("entries", []):
            if e["id"] in decisions:
                e["decided"] = True
                e["decision"] = decisions[e["id"]]
        return jsonify(q)

    @app.post("/api/decide")
    def api_decide():
        body = request.get_json(force=True) or {}
        entry_id = body.get("id")
        decision = body.get("decision")
        if not entry_id or decision not in ("approve", "reject", "defer"):
            return jsonify({"error": "id + decision (approve|reject|defer) required"}), 400
        decisions = load_decisions(decisions_path)
        decisions[entry_id] = decision
        save_decisions(decisions_path, decisions)
        return jsonify({"ok": True, "saved": {entry_id: decision}, "total": len(decisions)})

    @app.post("/api/batch-decide")
    def api_batch_decide():
        body = request.get_json(force=True) or {}
        incoming = body.get("decisions", {})
        if not isinstance(incoming, dict):
            return jsonify({"error": "decisions must be an object"}), 400
        decisions = load_decisions(decisions_path)
        added = 0
        for entry_id, decision in incoming.items():
            if decision not in ("approve", "reject", "defer"):
                continue
            decisions[entry_id] = decision
            added += 1
        save_decisions(decisions_path, decisions)
        return jsonify({"ok": True, "saved": added, "total": len(decisions)})

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

    app = make_app(args.config, args.data_dir)
    url = f"http://localhost:{port}/"
    print(f"clean-wiki review UI → {url}")
    if auto_open:
        open_browser_after(url)
    app.run(host="127.0.0.1", port=port, debug=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
