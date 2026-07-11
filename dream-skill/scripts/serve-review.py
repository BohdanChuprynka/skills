#!/usr/bin/env python3
"""Serve Dream's local review UI without third-party dependencies."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


SKILL_DIR = Path(__file__).resolve().parent.parent
DEFAULT_HOME = Path.home() / ".claude" / "dream-skill"
MAX_BODY_BYTES = 1_000_000
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "[::1]", "::1"}


def load_json(path: Path, default: object) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def save_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def host_name(raw: str) -> str:
    if raw.startswith("["):
        return raw.split("]", 1)[0] + "]"
    return raw.rsplit(":", 1)[0] if ":" in raw else raw


def make_handler(
    queue_path: Path,
    decisions_path: Path,
    html_path: Path,
    token: str,
) -> type[BaseHTTPRequestHandler]:
    decisions_lock = threading.Lock()

    class ReviewHandler(BaseHTTPRequestHandler):
        server_version = "DreamReview/1"

        def log_message(self, fmt: str, *args: object) -> None:
            print(f"review: {self.address_string()} {fmt % args}")

        def send_bytes(self, status: int, payload: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                "style-src 'self' 'unsafe-inline'; connect-src 'self'; "
                "img-src 'self' data:; frame-ancestors 'none'",
            )
            self.end_headers()
            self.wfile.write(payload)

        def send_json(self, value: object, status: int = HTTPStatus.OK) -> None:
            payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_bytes(status, payload, "application/json; charset=utf-8")

        def api_authorized(self) -> bool:
            if host_name(self.headers.get("Host", "")) not in ALLOWED_HOSTS:
                self.send_json({"error": "invalid host"}, HTTPStatus.FORBIDDEN)
                return False
            supplied = self.headers.get("X-CSRF-Token", "")
            if not supplied:
                supplied = parse_qs(urlsplit(self.path).query).get("token", [""])[0]
            if not supplied or not secrets.compare_digest(
                supplied.encode("utf-8"), token.encode("utf-8")
            ):
                self.send_json({"error": "forbidden"}, HTTPStatus.FORBIDDEN)
                return False
            return True

        def read_body(self) -> dict[str, object] | None:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY_BYTES:
                self.send_json({"error": "invalid body size"}, HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                return None
            try:
                value = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self.send_json({"error": "invalid JSON"}, HTTPStatus.BAD_REQUEST)
                return None
            if not isinstance(value, dict):
                self.send_json({"error": "JSON object required"}, HTTPStatus.BAD_REQUEST)
                return None
            return value

        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            if path == "/":
                try:
                    payload = html_path.read_bytes()
                except OSError:
                    self.send_bytes(HTTPStatus.NOT_FOUND, b"review UI missing\n", "text/plain")
                    return
                self.send_bytes(HTTPStatus.OK, payload, "text/html; charset=utf-8")
                return
            if not path.startswith("/api/"):
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            if not self.api_authorized():
                return
            if path == "/api/queue":
                queue = load_json(queue_path, None)
                if not isinstance(queue, dict):
                    self.send_json({"error": "review-input.json missing or invalid"}, HTTPStatus.NOT_FOUND)
                    return
                decisions = load_json(decisions_path, {})
                decisions = decisions if isinstance(decisions, dict) else {}
                entries = queue.get("entries", [])
                if isinstance(entries, list):
                    for entry in entries:
                        if isinstance(entry, dict) and entry.get("id") in decisions:
                            entry["decided"] = True
                            entry["decision"] = decisions[entry["id"]]
                self.send_json(queue)
            elif path == "/api/decisions":
                decisions = load_json(decisions_path, {})
                self.send_json(decisions if isinstance(decisions, dict) else {})
            else:
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:
            path = urlsplit(self.path).path
            if not path.startswith("/api/"):
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            if not self.api_authorized():
                return
            body = self.read_body()
            if body is None:
                return
            if path == "/api/decide":
                entry_id = body.get("id")
                decision = body.get("decision")
                if not isinstance(entry_id, str) or not entry_id or decision not in {"approve", "reject", "defer"}:
                    self.send_json({"error": "id and approve|reject|defer required"}, HTTPStatus.BAD_REQUEST)
                    return
                with decisions_lock:
                    decisions = load_json(decisions_path, {})
                    decisions = decisions if isinstance(decisions, dict) else {}
                    decisions[entry_id] = decision
                    save_json(decisions_path, decisions)
                self.send_json({"ok": True, "saved": {entry_id: decision}, "total": len(decisions)})
            elif path == "/api/batch-decide":
                incoming = body.get("decisions")
                if not isinstance(incoming, dict):
                    self.send_json({"error": "decisions object required"}, HTTPStatus.BAD_REQUEST)
                    return
                with decisions_lock:
                    decisions = load_json(decisions_path, {})
                    decisions = decisions if isinstance(decisions, dict) else {}
                    added = 0
                    for entry_id, decision in incoming.items():
                        if isinstance(entry_id, str) and decision in {"approve", "reject", "defer"}:
                            decisions[entry_id] = decision
                            added += 1
                    save_json(decisions_path, decisions)
                self.send_json({"ok": True, "saved": added, "total": len(decisions)})
            elif path == "/api/shutdown":
                self.send_json({"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    return ReviewHandler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue", type=Path, default=DEFAULT_HOME / "queue/review-input.json")
    parser.add_argument("--decisions", type=Path, default=DEFAULT_HOME / "queue/review-decisions.json")
    parser.add_argument("--web", type=Path, default=SKILL_DIR / "web")
    parser.add_argument("--port", type=int, default=5174)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    html_path = args.web / "dream-review.html"
    if not html_path.is_file():
        parser.error(f"review UI not found: {html_path}")
    token = secrets.token_urlsafe(32)
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port),
        make_handler(args.queue, args.decisions, html_path, token),
    )
    url = f"http://localhost:{args.port}/?token={token}"
    print(f"dream-skill review UI -> {url}", flush=True)
    if not args.no_browser:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
