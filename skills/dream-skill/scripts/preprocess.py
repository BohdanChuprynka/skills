#!/usr/bin/env python3
"""
preprocess.py — clean Claude Code session JSONLs into a user-biased signal transcript.

Filter policy (user-biased):
  - USER messages: kept (truncated); marked with "star" if matching a signal pattern.
  - ASSISTANT messages: dropped by default. Kept only if they contain "?" OR
    the immediately-following user reply is short (<SHORT_REPLY_CHARS).
  - System reminders, hook output, tool-call / tool-result blocks: dropped.

Signal patterns are loaded from a TOML file (see --signal-patterns) so the
patterns can be tuned per-user without editing this script. If no file is
supplied or it can't be parsed, generic life-state defaults are used — these
are deliberately broad (goals / role-change / project-status / body / schedule /
relationships) and contain NO personal entity names.

Examples:
    python preprocess.py --since 7d > sessions.md
    python preprocess.py --since 24h --signal-patterns ./my-patterns.toml > recent.md
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

DEFAULT_SESSIONS_ROOT = Path(os.environ.get(
    "DREAM_SESSIONS_ROOT",
    str(Path.home() / ".claude" / "projects"),
))
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

# Filtering thresholds (tuned for typical Claude Code transcripts)
MIN_REAL_USER_CHARS = 8
USER_MSG_MAX = 800
ASST_MSG_MAX = 500
SHORT_REPLY_CHARS = 60
MAX_MSGS_PER_SESSION = 15


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
    """Extract text from Claude message content (string OR list of content blocks)."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "text":
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

def process_session(
    path: Path,
    cutoff: datetime,
    signal_re: re.Pattern,
    star_only: bool = True,
) -> list:
    """Walk one JSONL, return formatted message lines with user-biased filter."""
    out: list = []
    session_id = path.stem
    header_added = False
    pending_asst = None
    msg_count = 0

    def ensure_header():
        nonlocal header_added
        if not header_added:
            out.append(f"\n--- session {session_id} ---")
            header_added = True

    for line in path.open(encoding="utf-8", errors="ignore"):
        if msg_count >= MAX_MSGS_PER_SESSION:
            break

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
        if not text or NOISE_PATTERNS.match(text):
            continue

        if kind == "user":
            real_text = strip_sysreminders(text)
            if len(real_text) < MIN_REAL_USER_CHARS:
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


# ============================================================
# Driver
# ============================================================

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Preprocess Claude Code session logs into a user-biased signal transcript.",
    )
    ap.add_argument(
        "--sessions-root",
        default=str(DEFAULT_SESSIONS_ROOT),
        help="Root directory of Claude Code session JSONLs "
             "(default: $DREAM_SESSIONS_ROOT or ~/.claude/projects)",
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
    args = ap.parse_args()

    star_only = not args.all
    cutoff = datetime.now(timezone.utc) - parse_since(args.since)
    root = Path(args.sessions_root).expanduser()

    if not root.exists():
        print(f"preprocess.py: sessions root not found: {root}", file=sys.stderr)
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

    for jsonl in root.rglob("*.jsonl"):
        total_files += 1
        try:
            if jsonl.stat().st_mtime < cutoff.timestamp():
                continue
        except OSError:
            continue

        session_lines = process_session(jsonl, cutoff, signal_re, star_only=star_only)
        if not session_lines:
            continue

        kept_files += 1
        signal_msgs += sum(1 for ln in session_lines if "[★]" in ln)
        all_lines.extend(session_lines)

    mode = "star-only" if star_only else "all-user"
    header = [
        f"# Cleaned Claude Code session signals — window: last {args.since} | mode: {mode}",
        f"# Files scanned: {total_files} | files kept: {kept_files} | signal-marked messages: {signal_msgs}",
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
