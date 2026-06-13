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
import secrets
import signal
import sys
import threading
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

# Flask's dev server is threaded; serialize the read-modify-write of the
# decisions file so concurrent swipe handlers can't drop/clobber writes.
_decisions_lock = threading.Lock()
_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}


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


def make_app(queue_path: Path, decisions_path: Path, web_dir: Path, token: str) -> Flask:
    app = Flask(__name__, static_folder=str(web_dir), static_url_path="")
    app.config["DREAM_TOKEN"] = token

    @app.before_request
    def _guard_api():
        # Only the data API needs guarding; the static shell is harmless.
        if not request.path.startswith("/api/"):
            return None
        # DNS-rebinding defense: Host must be loopback.
        host = (request.host or "").rsplit(":", 1)[0]
        if host not in _LOOPBACK_HOSTS:
            return jsonify({"error": "invalid host"}), 403
        # CSRF defense: require the per-run token (not a cookie, so a cross-site
        # page cannot have it auto-attached and cannot read it).
        supplied = request.headers.get("X-CSRF-Token") or request.args.get("token", "")
        # .encode() both sides: compare_digest raises TypeError on non-ASCII str,
        # which would surface as a 500 instead of a clean 403.
        if not supplied or not secrets.compare_digest(
            supplied.encode("utf-8"), app.config["DREAM_TOKEN"].encode("utf-8")
        ):
            return jsonify({"error": "forbidden"}), 403
        return None

    @app.route("/")
    def index():
        if not web_dir.exists() or not (web_dir / "dream-review.html").exists():
            return "web/dream-review.html missing", 500
        return send_from_directory(web_dir, "dream-review.html")

    @app.get("/api/queue")
    def api_queue():
        if not queue_path.exists():
            return jsonify({"error": "review-input.json not found — run /dream-skill first"}), 404
        try:
            q = json.loads(queue_path.read_text())
        except json.JSONDecodeError:
            return jsonify({"error": "review-input.json is not valid JSON"}), 500
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

    # Per-run CSRF token. The UI reads it from the URL and echoes it on every
    # /api/* call; without it the data API rejects the request.
    token = secrets.token_urlsafe(32)
    app = make_app(args.queue, args.decisions, args.web, token)
    url = f"http://localhost:{args.port}/?token={token}"
    print(f"dream-skill review UI → {url}")
    print("  (open the URL above — the token gates the review API)")
    if not args.no_browser:
        Timer(0.8, lambda: webbrowser.open(url)).start()
    app.run(host="127.0.0.1", port=args.port, debug=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
