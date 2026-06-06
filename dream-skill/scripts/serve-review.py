#!/usr/bin/env python3
"""dream-skill review server — serves the flip-card review UI at http://localhost:5174.

Reads queue/review-input.json (built by build-review-queue.py before launch).
Captures decisions to queue/review-decisions.json (incremental, resumable).
Shuts down on POST /api/shutdown so the orchestrating Claude knows the user is done.

Usage:
    serve-review.py [--queue PATH] [--decisions PATH] [--web PATH] [--port PORT] [--no-browser]
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import webbrowser
from pathlib import Path
from threading import Timer

from flask import Flask, jsonify, request, send_from_directory


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
DEFAULT_WEB_DIR = SKILL_DIR / "web"
DEFAULT_DREAM_HOME = Path.home() / ".claude" / "dream-skill"
DEFAULT_QUEUE = DEFAULT_DREAM_HOME / "queue" / "review-input.json"
DEFAULT_DECISIONS = DEFAULT_DREAM_HOME / "queue" / "review-decisions.json"


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


def make_app(queue_path: Path, decisions_path: Path, web_dir: Path) -> Flask:
    app = Flask(__name__, static_folder=str(web_dir), static_url_path="")

    @app.route("/")
    def index():
        if not web_dir.exists() or not (web_dir / "dream-review.html").exists():
            return "web/dream-review.html missing", 500
        return send_from_directory(web_dir, "dream-review.html")

    @app.get("/api/queue")
    def api_queue():
        if not queue_path.exists():
            return jsonify({"error": "review-input.json not found — run /dream-skill first"}), 404
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
        def _die():
            os.kill(os.getpid(), signal.SIGTERM)
        Timer(0.3, _die).start()
        return jsonify({"ok": True})

    return app


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--queue",     type=Path, default=DEFAULT_QUEUE)
    ap.add_argument("--decisions", type=Path, default=DEFAULT_DECISIONS)
    ap.add_argument("--web",       type=Path, default=DEFAULT_WEB_DIR)
    ap.add_argument("--port",      type=int,  default=5174)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    app = make_app(args.queue, args.decisions, args.web)
    url = f"http://localhost:{args.port}/"
    print(f"dream-skill review UI → {url}")
    if not args.no_browser:
        Timer(0.8, lambda: webbrowser.open(url)).start()
    app.run(host="127.0.0.1", port=args.port, debug=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
