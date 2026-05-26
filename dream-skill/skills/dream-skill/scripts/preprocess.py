#!/usr/bin/env python3
"""
preprocess.py — clean local agent conversation JSONLs into a readable transcript.

Policy:
  - USER messages: kept (head+tail truncated only if very long).
  - ASSISTANT messages: dropped by default. Kept only if they contain "?" OR
    the immediately-following user reply is short (< SHORT_REPLY_CHARS).
  - System reminders, hook output, tool-call / tool-result blocks: dropped.

Supported local conversation sources:
  - Claude Code JSONLs under ~/.claude/projects
  - Codex CLI JSONLs under ~/.codex/sessions

Time window:
  - If --since is passed (e.g. 14d), it wins.
  - Otherwise the cutoff comes from <skill-root>/.last-run (ISO timestamp written
    by dream.sh after a successful reconcile), capped at CAP_DAYS lookback so a
    long absence doesn't dump months of history into a single LLM call.

Examples:
    python preprocess.py --sources claude,codex --output sessions.md
    python preprocess.py --since 14d --output -
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


# ============================================================
# Defaults
# ============================================================

DEFAULT_CLAUDE_SESSIONS_ROOT = Path(os.environ.get(
    "DREAM_CLAUDE_SESSIONS_ROOT",
    os.environ.get("DREAM_SESSIONS_ROOT", str(Path.home() / ".claude" / "projects")),
))
DEFAULT_CODEX_SESSIONS_ROOT = Path(os.environ.get(
    "DREAM_CODEX_SESSIONS_ROOT",
    str(Path.home() / ".codex" / "sessions"),
))
DEFAULT_SOURCES = os.environ.get("DREAM_CONVERSATION_SOURCES", "claude,codex")
DEFAULT_OUTPUT = Path("/tmp/dream-sessions.md")

# Last-run file lives at the skill root (one level above scripts/).
LAST_RUN_FILE = Path(__file__).resolve().parent.parent / ".last-run"

# Maximum lookback when no --since is passed and .last-run is missing or stale.
CAP_DAYS = 30

# Truncation: keep full message unless very long, then head + cut-marker + tail.
HEAD_CHARS = 1000
TAIL_CHARS = 1000
TRUNCATE_THRESHOLD = HEAD_CHARS + TAIL_CHARS  # 2000

# Assistant-anchor heuristic: short user replies need preceding context.
SHORT_REPLY_CHARS = 60

NOISE_PATTERNS = re.compile(
    r"^(?:\s*<system-reminder|"
    r"<command-name|"
    r"<command-message|"
    r"<command-args|"
    r"<local-command-(?:stdout|stderr)|"
    r"<bash-(?:stdout|stderr)|"
    r"<user-prompt-submit-hook|"
    r"<task-notification|"
    r"<tool-use-id|"
    r"Caveat: The messages below|"
    r"Base directory for this skill:|"
    r"Tool loaded\.?$|"
    r"\[Request interrupted)",
    re.IGNORECASE,
)

SYSREMINDER_BLOCK = re.compile(
    r"<system-reminder>.*?</system-reminder>",
    re.DOTALL | re.IGNORECASE,
)

# ----- coding-dump filter -----
# Heuristic drops messages that are predominantly code/error/path/shell content
# while keeping short technical questions and persona-mixed discussions.
CODING_DUMP_MIN_LEN = 300  # messages shorter than this are always kept

CODE_FENCE_BLOCK = re.compile(r"```.*?```", re.DOTALL)

ERROR_MARKER = re.compile(
    r"\b(?:Traceback|TypeError|ValueError|RuntimeError|Exception|"
    r"SyntaxError|ImportError|AttributeError|KeyError|IndexError|"
    r"NameError|ZeroDivisionError|OSError|"
    r"undefined is not (?:a function|an object)|cannot read prop(?:erty)?|"
    r"NoneType|"
    r"at line \d+|File \".+?\", line)\b"
)

SHELL_PROMPT_LINE = re.compile(r"^\s*(?:\$|>>>|#\s|\+\s)")

PATH_OR_FILE_TOKEN = re.compile(
    r"(?:[/~]|\./|\.\./)[\w./\-]+|"
    r"\b\w+\.(?:ts|tsx|py|js|jsx|sh|json|yaml|yml|toml|css|html|rs|go|rb|java|cpp|c|h|md)\b"
)

# Agent-task assignment prefix: "You are <doing-code-thing>...".
# Note: "you are drafting/reviewing/writing (prose)" deliberately NOT included
# because that pattern often wraps persona-relevant content (e.g. cold outreach).
AGENT_CODE_TASK_PREFIX = re.compile(
    r"^\s*you are (?:implementing|refactoring|building|fixing|debugging|"
    r"porting|migrating|optimizing|integrating|deploying|writing tests|"
    r"adding|removing|updating the|cleaning up|wiring up)",
    re.IGNORECASE,
)

SOURCE_LABELS = {
    "claude": "Claude Code",
    "codex": "Codex CLI",
}


# ============================================================
# Helpers
# ============================================================

def parse_since(s: str) -> timedelta:
    """Parse '7d', '24h', '30m' etc."""
    m = re.match(r"^(\d+)([dhm])$", s)
    if not m:
        raise ValueError(f"invalid --since: {s} (expected 7d / 24h / 30m form)")
    n, unit = int(m.group(1)), m.group(2)
    return {"d": timedelta(days=n), "h": timedelta(hours=n), "m": timedelta(minutes=n)}[unit]


def read_last_run() -> datetime | None:
    """Return the timestamp recorded by the previous successful dream run, or None."""
    if not LAST_RUN_FILE.is_file():
        return None
    try:
        raw = LAST_RUN_FILE.read_text(encoding="utf-8").strip()
        if not raw:
            return None
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, OSError):
        return None


def resolve_cutoff(since_arg: str | None, verbose: bool = False) -> tuple[datetime, str]:
    """Decide the cutoff datetime and a human-readable window label."""
    now = datetime.now(timezone.utc)
    cap = now - timedelta(days=CAP_DAYS)

    if since_arg:
        cutoff = now - parse_since(since_arg)
        return cutoff, f"explicit --since {since_arg}"

    last_run = read_last_run()
    if last_run is None:
        if verbose:
            print(f"# .last-run missing → using {CAP_DAYS}d cap", file=sys.stderr)
        return cap, f"no .last-run → {CAP_DAYS}d cap"

    if last_run < cap:
        if verbose:
            print(f"# .last-run older than {CAP_DAYS}d → using cap", file=sys.stderr)
        return cap, f".last-run older than cap → {CAP_DAYS}d"

    return last_run, f"since last run ({last_run.isoformat()})"


def extract_text(content) -> str:
    """Extract text from message content (string OR list of text-bearing blocks)."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts = []
    for c in content:
        if isinstance(c, dict) and isinstance(c.get("text"), str):
            parts.append(c.get("text", ""))
    return "\n".join(parts).strip()


def parse_timestamp(evt: dict):
    ts = evt.get("timestamp")
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def parse_sources(value: str) -> list[str]:
    raw = [part.strip().lower() for part in value.split(",") if part.strip()]
    if not raw or "all" in raw:
        raw = ["claude", "codex"]

    out = []
    invalid = []
    for source in raw:
        if source not in SOURCE_LABELS:
            invalid.append(source)
            continue
        if source not in out:
            out.append(source)

    if invalid:
        allowed = ", ".join(sorted(SOURCE_LABELS))
        raise ValueError(f"invalid --sources value(s): {', '.join(invalid)}; expected {allowed} or all")
    return out


def _truncate(text: str) -> str:
    """Keep text intact unless very long; otherwise emit head + cut-marker + tail."""
    n = len(text)
    if n <= TRUNCATE_THRESHOLD:
        return text
    cut = n - HEAD_CHARS - TAIL_CHARS
    return f"{text[:HEAD_CHARS]}\n[…{cut} chars cut…]\n{text[-TAIL_CHARS:]}"


def is_tool_result_user_msg(content) -> bool:
    """User messages with tool_result blocks are tool plumbing, not real user input."""
    if not isinstance(content, list):
        return False
    return any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content)


def strip_sysreminders(text: str) -> str:
    """Remove <system-reminder>...</system-reminder> blocks. Empty result means noise."""
    return SYSREMINDER_BLOCK.sub("", text).strip()


def is_coding_dump(text: str) -> bool:
    """Heuristic: True if message is predominantly code/error/path/shell content.

    Short messages (< CODING_DUMP_MIN_LEN) are never flagged — this protects
    short technical questions like "how do I X in React".
    """
    n = len(text)
    if n < CODING_DUMP_MIN_LEN:
        return False

    # 1. Agent-task assignment ("You are implementing/refactoring/...")
    if AGENT_CODE_TASK_PREFIX.match(text):
        return True

    # 2. Substantial fenced code block (any length, beyond a tiny snippet)
    code_chars = sum(len(m.group(0)) for m in CODE_FENCE_BLOCK.finditer(text))
    if code_chars > 0:
        if code_chars > 500 or (n > 0 and code_chars / n > 0.4):
            return True

    # 3. Stack trace / error markers (≥2 hits)
    if len(ERROR_MARKER.findall(text)) >= 2:
        return True

    # 4. Shell output dump (many lines starting with $, >>>, #, +)
    lines = text.splitlines()
    if len(lines) > 5:
        shell_lines = sum(1 for ln in lines if SHELL_PROMPT_LINE.match(ln))
        if shell_lines / len(lines) > 0.3:
            return True

    # 5. Heavy file-path / source-extension token density
    words = text.split()
    if len(words) > 50:
        path_tokens = len(PATH_OR_FILE_TOKEN.findall(text))
        if path_tokens / len(words) > 0.10:
            return True

    return False


def _format_session_header(source: str, ts: datetime | None) -> str:
    if ts is None:
        return f"\n--- {source} session ---"
    stamp = ts.astimezone().strftime("%Y-%m-%d %H:%M")
    return f"\n--- {source} {stamp} ---"


# ============================================================
# Per-session processing
# ============================================================

def emit_messages(
    messages: list[tuple[str, str, datetime | None]],
    source: str,
    filter_enabled: bool = True,
) -> tuple[list[str], dict[str, int]]:
    """Format normalized (kind, text, ts) triples into transcript lines.

    Returns (lines, stats) where stats counts kept_user, kept_asst, dropped_coding.
    """
    out: list = []
    stats = {"kept_user": 0, "kept_asst": 0, "dropped_coding": 0}
    header_added = False
    header_ts: datetime | None = None
    pending_asst: str | None = None

    def ensure_header():
        nonlocal header_added
        if not header_added:
            out.append(_format_session_header(source, header_ts))
            header_added = True

    for kind, text, ts in messages:
        if not text or NOISE_PATTERNS.match(text):
            continue

        if kind == "user":
            real_text = strip_sysreminders(text)
            if not real_text:
                continue
            text = real_text

            if filter_enabled and is_coding_dump(text):
                stats["dropped_coding"] += 1
                pending_asst = None  # ASST that preceded a dropped user is orphaned
                continue

            short_reply = len(text) < SHORT_REPLY_CHARS

            if pending_asst is not None:
                if "?" in pending_asst or short_reply:
                    if header_ts is None:
                        header_ts = ts
                    ensure_header()
                    out.append(f"      ASST: {_truncate(pending_asst)}")
                    stats["kept_asst"] += 1
                pending_asst = None

            if header_ts is None:
                header_ts = ts
            ensure_header()
            out.append(f"USER: {_truncate(text)}")
            stats["kept_user"] += 1

        elif kind == "assistant":
            pending_asst = text

    # Trailing assistant question (no following user reply within window)
    if pending_asst is not None and "?" in pending_asst:
        ensure_header()
        out.append(f"      ASST: {_truncate(pending_asst)}")
        stats["kept_asst"] += 1

    return out, stats


def process_claude_session(
    path: Path,
    cutoff: datetime,
    filter_enabled: bool = True,
) -> tuple[list[str], dict[str, int]]:
    """Walk one Claude Code JSONL → (lines, stats)."""
    messages: list[tuple[str, str, datetime | None]] = []

    for line in path.open(encoding="utf-8", errors="ignore"):
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue

        if evt.get("isMeta") or evt.get("isCompactSummary"):
            continue

        ts = parse_timestamp(evt)
        if ts and ts < cutoff:
            continue

        kind = evt.get("type")
        if kind not in ("user", "assistant"):
            continue

        msg = evt.get("message") or evt
        content = msg.get("content") if isinstance(msg, dict) else None
        if content is None:
            continue

        if kind == "user" and is_tool_result_user_msg(content):
            continue

        text = extract_text(content)
        if text:
            messages.append((kind, text, ts))

    return emit_messages(messages, source="claude", filter_enabled=filter_enabled)


def codex_event_message(evt: dict) -> tuple[str, str] | None:
    """Extract actual Codex UI/CLI message events, excluding tool/log mirrors."""
    payload = evt.get("payload")
    if not isinstance(payload, dict):
        return None

    payload_type = payload.get("type")
    if payload_type == "user_message":
        text = payload.get("message")
        return ("user", text.strip()) if isinstance(text, str) else None
    if payload_type == "agent_message":
        text = payload.get("message")
        return ("assistant", text.strip()) if isinstance(text, str) else None
    return None


def codex_response_item_message(evt: dict) -> tuple[str, str] | None:
    """Fallback extractor for Codex response_item message records."""
    if evt.get("type") != "response_item":
        return None
    payload = evt.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "message":
        return None

    role = payload.get("role")
    if role not in ("user", "assistant"):
        return None

    text = extract_text(payload.get("content"))
    if not text:
        return None
    return (role, text)


def is_codex_cli_session(path: Path) -> bool:
    """Return True only for Codex CLI-generated local session JSONLs."""
    for line in path.open(encoding="utf-8", errors="ignore"):
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue
        if evt.get("type") != "session_meta":
            continue
        payload = evt.get("payload")
        if not isinstance(payload, dict):
            return False
        originator = str(payload.get("originator", "")).lower()
        source = payload.get("source")
        if originator in {"codex-tui", "codex-cli"}:
            return True
        if isinstance(source, str) and source.lower() == "cli":
            return True
        return False
    return False


def process_codex_session(
    path: Path,
    cutoff: datetime,
    filter_enabled: bool = True,
) -> tuple[list[str], dict[str, int]]:
    """Walk one Codex CLI JSONL → (lines, stats)."""
    event_messages: list[tuple[str, str, datetime | None]] = []
    response_messages: list[tuple[str, str, datetime | None]] = []

    for line in path.open(encoding="utf-8", errors="ignore"):
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue

        ts = parse_timestamp(evt)
        if ts and ts < cutoff:
            continue

        event_msg = codex_event_message(evt)
        if event_msg is not None:
            event_messages.append((event_msg[0], event_msg[1], ts))
            continue

        response_msg = codex_response_item_message(evt)
        if response_msg is not None:
            response_messages.append((response_msg[0], response_msg[1], ts))

    messages = event_messages if event_messages else response_messages
    return emit_messages(messages, source="codex", filter_enabled=filter_enabled)


# ============================================================
# Driver
# ============================================================

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Preprocess local Claude Code and Codex CLI logs into a readable transcript.",
    )
    ap.add_argument(
        "--sessions-root",
        default=str(DEFAULT_CLAUDE_SESSIONS_ROOT),
        help="Root directory of Claude Code session JSONLs. Backward-compatible alias "
             "for --claude-sessions-root.",
    )
    ap.add_argument(
        "--claude-sessions-root",
        default=None,
        help="Root directory of Claude Code session JSONLs "
             "(default: $DREAM_CLAUDE_SESSIONS_ROOT, $DREAM_SESSIONS_ROOT, or ~/.claude/projects)",
    )
    ap.add_argument(
        "--codex-sessions-root",
        default=str(DEFAULT_CODEX_SESSIONS_ROOT),
        help="Root directory of Codex CLI session JSONLs "
             "(default: $DREAM_CODEX_SESSIONS_ROOT or ~/.codex/sessions)",
    )
    ap.add_argument(
        "--sources",
        default=DEFAULT_SOURCES,
        help="Comma-separated sources to scan: claude,codex, or all "
             "(default: $DREAM_CONVERSATION_SOURCES or claude,codex)",
    )
    ap.add_argument(
        "--since",
        default=None,
        help=f"Time window: 7d / 24h / 30m form. When omitted, the cutoff is read "
             f"from .last-run (capped at {CAP_DAYS}d lookback).",
    )
    ap.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="Output file path (default: /tmp/dream-sessions.md). Use '-' for stdout.",
    )
    ap.add_argument(
        "--no-filter",
        action="store_true",
        help="Disable the coding-dump filter (keep every user message regardless of "
             "code/error/path density). Useful for diagnostics + comparison.",
    )
    ap.add_argument(
        "--verbose",
        action="store_true",
        help="Print debug info to stderr (cutoff resolution, file scan progress)",
    )
    args = ap.parse_args(argv)
    filter_enabled = not args.no_filter

    try:
        cutoff, window_label = resolve_cutoff(args.since, verbose=args.verbose)
        sources = parse_sources(args.sources)
    except ValueError as e:
        print(f"preprocess.py: {e}", file=sys.stderr)
        return 1

    all_lines: list = []
    total_files = 0
    kept_files = 0
    available_roots = 0
    stats: dict[str, dict[str, int]] = {}

    claude_root = Path(args.claude_sessions_root or args.sessions_root).expanduser()
    codex_root = Path(args.codex_sessions_root).expanduser()
    source_roots = {
        "claude": claude_root,
        "codex": codex_root,
    }
    processors = {
        "claude": process_claude_session,
        "codex": process_codex_session,
    }

    for source in sources:
        root = source_roots[source]
        stats[source] = {
            "scanned": 0,
            "kept": 0,
            "kept_user": 0,
            "kept_asst": 0,
            "dropped_coding": 0,
        }
        if not root.exists():
            print(f"# WARN: {source} sessions root not found: {root}", file=sys.stderr)
            continue
        if not root.is_dir():
            print(f"# WARN: {source} sessions root is not a directory: {root}", file=sys.stderr)
            continue

        available_roots += 1
        for jsonl in root.rglob("*.jsonl"):
            total_files += 1
            stats[source]["scanned"] += 1
            try:
                if jsonl.stat().st_mtime < cutoff.timestamp():
                    continue
            except OSError:
                continue

            if source == "codex" and not is_codex_cli_session(jsonl):
                continue

            session_lines, session_stats = processors[source](
                jsonl, cutoff, filter_enabled=filter_enabled,
            )
            stats[source]["kept_user"] += session_stats["kept_user"]
            stats[source]["kept_asst"] += session_stats["kept_asst"]
            stats[source]["dropped_coding"] += session_stats["dropped_coding"]
            if not session_lines:
                continue

            kept_files += 1
            stats[source]["kept"] += 1
            all_lines.extend(session_lines)

    if available_roots == 0:
        selected = ", ".join(sources)
        print(f"preprocess.py: no selected conversation roots found: {selected}", file=sys.stderr)
        return 1

    source_labels = ", ".join(SOURCE_LABELS[source] for source in sources)
    source_stats = "; ".join(
        f"{SOURCE_LABELS[source]} scanned {stats[source]['scanned']}, "
        f"kept {stats[source]['kept']}, "
        f"user {stats[source]['kept_user']}, "
        f"asst {stats[source]['kept_asst']}, "
        f"dropped(coding) {stats[source]['dropped_coding']}"
        for source in sources
    )
    total_user = sum(stats[s]["kept_user"] for s in sources)
    total_asst = sum(stats[s]["kept_asst"] for s in sources)
    total_dropped = sum(stats[s]["dropped_coding"] for s in sources)
    filter_label = "off" if not filter_enabled else "on (coding-dump heuristic)"
    header = [
        f"# Local conversation transcript — window: {window_label}",
        f"# Sources: {source_labels}",
        f"# Filter: {filter_label}",
        f"# Files scanned: {total_files} | files kept: {kept_files}",
        f"# Messages kept: {total_user} user, {total_asst} asst | dropped (coding): {total_dropped}",
        f"# Source stats: {source_stats}",
        f"# Cutoff: {cutoff.isoformat()}",
        "",
    ]

    body = "\n".join(header + all_lines) + "\n"

    if args.output == "-":
        sys.stdout.write(body)
    else:
        out_path = Path(args.output).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(body, encoding="utf-8")
        if args.verbose:
            print(f"# wrote {out_path} ({out_path.stat().st_size} bytes)", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
