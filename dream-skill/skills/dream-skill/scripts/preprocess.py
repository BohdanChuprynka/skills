#!/usr/bin/env python3
"""
preprocess.py — clean local agent conversation JSONLs into a user-biased signal transcript.

Filter policy (user-biased):
  - USER messages: kept (truncated); marked with "star" if matching a signal pattern.
  - ASSISTANT messages: dropped by default. Kept only if they contain "?" OR
    the immediately-following user reply is short (<SHORT_REPLY_CHARS).
  - System reminders, hook output, tool-call / tool-result blocks: dropped.

Supported local conversation sources:
  - Claude Code JSONLs under ~/.claude/projects
  - Codex CLI JSONLs under ~/.codex/sessions

Signal patterns are loaded from a TOML file (see --signal-patterns) so the
patterns can be tuned per-user without editing this script. If no file is
supplied or it can't be parsed, generic life-state defaults are used — these
are deliberately broad (goals / role-change / project-status / body / schedule /
relationships) and contain NO personal entity names.

Examples:
    python preprocess.py --since 7d --sources claude,codex > sessions.md
    python preprocess.py --since 24h --sources codex --signal-patterns ./my-patterns.toml > recent.md
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    import tomllib  # py3.11+
except ImportError:
    tomllib = None  # falls back to baked-in defaults


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
DEFAULT_SINCE = os.environ.get("DREAM_SINCE", "7d")

# Generic high-signal patterns — life-state changes, corrections, decisions.
# Bias toward recall: extra noise is fine, missing real signal is not.
# No personal entity names here; entity-specific patterns belong in a user-supplied TOML.
DEFAULT_SIGNAL_PATTERNS = [
    r"actually",
    r"no longer",
    r"switched",
    r"now (?:building|working|at|focused|using|trying)",
    r"anymore",
    r"moved to",
    r"started (?:working|building|using|seeing|dating|learning)",
    r"ended",
    r"decided",
    r"stopped",
    r"changed (?:my|to|the)",
    r"new (?:role|project|job|gym|partner|friend|mentor|goal|focus)",
    r"archived?",
    r"correct(?:ion)?",
    r"wrong",
    r"update memory",
    r"forget",
    r"i'?m (?:now|not|building|working|seeing|going to|trying|focusing)",
    r"we'?re (?:now|not|building|working)",
    r"current(?:ly)?",
    r"my (?:goal|priority|focus|status)",
]

NOISE_PATTERNS = re.compile(
    r"^(?:\s*<system-reminder|"
    r"<command-name|"
    r"<command-message|"
    r"<command-args|"
    r"<local-command-(?:stdout|stderr)|"
    r"<bash-(?:stdout|stderr)|"
    r"<user-prompt-submit-hook|"
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

# Filtering thresholds (tuned for local agent transcripts)
MIN_REAL_USER_CHARS = 8
USER_MSG_MAX = 800
ASST_MSG_MAX = 500
SHORT_REPLY_CHARS = 60
MAX_MSGS_PER_SESSION = 15

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


def _truncate(text: str, limit: int) -> str:
    return text[:limit] + ("…" if len(text) > limit else "")


def is_tool_result_user_msg(content) -> bool:
    """User messages with tool_result blocks are tool plumbing, not real user input."""
    if not isinstance(content, list):
        return False
    return any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content)


def strip_sysreminders(text: str) -> str:
    """Remove <system-reminder>...</system-reminder> blocks. If little/nothing remains,
    the caller treats the message as noise."""
    return SYSREMINDER_BLOCK.sub("", text).strip()


def load_signal_patterns(toml_path: Path | None, verbose: bool = False) -> re.Pattern:
    """Build the signal-matching regex from a TOML file or fall back to defaults."""
    patterns: list[str] = list(DEFAULT_SIGNAL_PATTERNS)

    if toml_path and toml_path.is_file() and tomllib is not None:
        try:
            data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        except Exception as e:
            if verbose:
                print(f"# WARN: could not parse {toml_path}: {e}", file=sys.stderr)
            data = {}

        high_signal = data.get("high_signal", {}) or {}
        # Append (don't replace) — user patterns add to defaults
        for key in ("life_state", "entities", "extra"):
            val = high_signal.get(key)
            if isinstance(val, list):
                patterns.extend(str(p) for p in val if p)

    # De-dup while preserving order
    seen = set()
    deduped = []
    for p in patterns:
        if p not in seen:
            seen.add(p)
            deduped.append(p)

    if verbose:
        print(f"# signal-pattern count: {len(deduped)}", file=sys.stderr)
    return re.compile(r"\b(" + "|".join(deduped) + r")\b", re.IGNORECASE)


# ============================================================
# Per-session processing
# ============================================================

def emit_filtered_messages(
    messages: list[tuple[str, str]],
    session_id: str,
    source: str,
    signal_re: re.Pattern,
    star_only: bool = True,
) -> list[str]:
    """Format normalized (kind, text) pairs with the user-biased filter."""
    out: list = []
    header_added = False
    pending_asst = None
    msg_count = 0

    def ensure_header():
        nonlocal header_added
        if not header_added:
            out.append(f"\n--- {source} session {session_id} ---")
            header_added = True

    for kind, text in messages:
        if msg_count >= MAX_MSGS_PER_SESSION:
            break

        if not text or NOISE_PATTERNS.match(text):
            continue

        if kind == "user":
            real_text = strip_sysreminders(text)
            if len(real_text) < MIN_REAL_USER_CHARS and pending_asst is None:
                continue
            text = real_text

        if kind == "user":
            is_signal = bool(signal_re.search(text))
            short_reply = len(text.strip()) < SHORT_REPLY_CHARS

            if star_only and not is_signal:
                pending_asst = None
                continue

            if pending_asst is not None:
                if "?" in pending_asst or short_reply:
                    ensure_header()
                    out.append(f"      ASST: {_truncate(pending_asst, ASST_MSG_MAX)}")
                    msg_count += 1
                pending_asst = None

            tag = "★" if is_signal else " "
            ensure_header()
            out.append(f"[{tag}] USER: {_truncate(text, USER_MSG_MAX)}")
            msg_count += 1

        elif kind == "assistant":
            pending_asst = text

    if (
        not star_only
        and pending_asst is not None
        and "?" in pending_asst
        and msg_count < MAX_MSGS_PER_SESSION
    ):
        ensure_header()
        out.append(f"      ASST: {_truncate(pending_asst, ASST_MSG_MAX)}")

    return out


def process_claude_session(
    path: Path,
    cutoff: datetime,
    signal_re: re.Pattern,
    star_only: bool = True,
) -> list[str]:
    """Walk one Claude Code JSONL and return formatted signal lines."""
    messages: list[tuple[str, str]] = []

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
            messages.append((kind, text))

    return emit_filtered_messages(
        messages,
        session_id=path.stem,
        source="claude",
        signal_re=signal_re,
        star_only=star_only,
    )


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
    """
    Fallback extractor for Codex response_item message records.

    Some Codex builds store the model conversation only as response_item rows.
    When event_msg user_message/agent_message rows exist, those are preferred
    because response_item rows can include context replay and developer input.
    """
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
    """
    Return True only for Codex CLI-generated local session JSONLs.

    Codex stores multiple local products under ~/.codex/sessions. The dream
    cycle intentionally excludes VS Code/Desktop-originated sessions even
    though they share the rollout JSONL shape.
    """
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
    signal_re: re.Pattern,
    star_only: bool = True,
) -> list[str]:
    """Walk one Codex CLI JSONL and return formatted signal lines."""
    event_messages: list[tuple[str, str]] = []
    response_messages: list[tuple[str, str]] = []

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
            event_messages.append(event_msg)
            continue

        response_msg = codex_response_item_message(evt)
        if response_msg is not None:
            response_messages.append(response_msg)

    messages = event_messages if event_messages else response_messages
    return emit_filtered_messages(
        messages,
        session_id=path.stem,
        source="codex",
        signal_re=signal_re,
        star_only=star_only,
    )


# ============================================================
# Driver
# ============================================================

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Preprocess local Claude Code and Codex CLI logs into a user-biased signal transcript.",
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
        default=DEFAULT_SINCE,
        help="Time window: 7d / 24h / 30m form (default: 7d or $DREAM_SINCE)",
    )
    ap.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="Output file path (default: /tmp/dream-sessions.md). "
             "Use '-' for stdout.",
    )
    ap.add_argument(
        "--signal-patterns",
        default=None,
        help="Path to signal-patterns.toml (optional; falls back to baked-in defaults)",
    )
    ap.add_argument(
        "--all",
        action="store_true",
        help="Emit ALL user messages, not just signal-matched. Larger output.",
    )
    ap.add_argument(
        "--verbose",
        action="store_true",
        help="Print debug info to stderr (pattern count, file scan progress)",
    )
    args = ap.parse_args(argv)

    star_only = not args.all
    try:
        cutoff = datetime.now(timezone.utc) - parse_since(args.since)
        sources = parse_sources(args.sources)
    except ValueError as e:
        print(f"preprocess.py: {e}", file=sys.stderr)
        return 1

    # Auto-resolve default signal-patterns path: <script-dir>/../config/signal-patterns.toml
    if args.signal_patterns is None:
        script_dir = Path(__file__).resolve().parent
        candidate = script_dir.parent / "config" / "signal-patterns.toml"
        sig_path = candidate if candidate.is_file() else None
    else:
        sig_path = Path(args.signal_patterns).expanduser()

    signal_re = load_signal_patterns(sig_path, verbose=args.verbose)

    all_lines: list = []
    total_files = 0
    kept_files = 0
    signal_msgs = 0
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
        stats[source] = {"scanned": 0, "kept": 0, "signals": 0}
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

            session_lines = processors[source](jsonl, cutoff, signal_re, star_only=star_only)
            if not session_lines:
                continue

            kept_files += 1
            stats[source]["kept"] += 1
            source_signal_msgs = sum(1 for ln in session_lines if "[★]" in ln)
            signal_msgs += source_signal_msgs
            stats[source]["signals"] += source_signal_msgs
            all_lines.extend(session_lines)

    if available_roots == 0:
        selected = ", ".join(sources)
        print(f"preprocess.py: no selected conversation roots found: {selected}", file=sys.stderr)
        return 1

    mode = "star-only" if star_only else "all-user"
    source_labels = ", ".join(SOURCE_LABELS[source] for source in sources)
    source_stats = "; ".join(
        f"{SOURCE_LABELS[source]} scanned {stats[source]['scanned']}, "
        f"kept {stats[source]['kept']}, signals {stats[source]['signals']}"
        for source in sources
    )
    header = [
        f"# Cleaned local conversation signals — window: last {args.since} | mode: {mode}",
        f"# Sources: {source_labels}",
        f"# Files scanned: {total_files} | files kept: {kept_files} | signal-marked messages: {signal_msgs}",
        f"# Source stats: {source_stats}",
        f"# Cutoff: {cutoff.isoformat()}",
        f"# Legend: star = matched high-signal pattern",
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
