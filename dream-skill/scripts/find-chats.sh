#!/usr/bin/env bash
# find-chats.sh — enumerate local Claude/Codex JSONL transcript files whose
# mtime falls inside the requested time window, skip --ignore'd chats, emit
# weekly batch boundaries for large windows.
#
# Usage:
#   find-chats.sh [--since <YYYY-MM-DD>] [--all] [--source claude|codex|all]
#
# Environment overrides (for tests):
#   DREAM_PROJECTS_ROOT        — legacy alias for DREAM_CLAUDE_PROJECTS_ROOT
#   DREAM_CLAUDE_PROJECTS_ROOT — replaces ~/.claude/projects
#   DREAM_CODEX_SESSIONS_ROOT  — replaces ~/.codex/sessions
#   DREAM_TRANSCRIPT_SOURCE    — source override: claude | codex | all (default: all)
#   DREAM_MARKER_DIR           — dir holding the `last-run` marker file
#   DREAM_SKILL_HOME           — plugin root (for scripts/private-state.sh)
#
# Output (stdout):
#   Lines of the form:
#       BATCH:<YYYY-MM-DD>:<YYYY-MM-DD>
#       <absolute-path-to-chat.jsonl>
#       <absolute-path-to-chat.jsonl>
#       BATCH:<YYYY-MM-DD>:<YYYY-MM-DD>   # next week boundary (--all only)
#       ...
#   A single BATCH header precedes all paths when the window is ≤7 days.
#   Multiple BATCH headers are emitted week-by-week for --all or large --since.
#
# Exit codes: 0 = success (even if zero chats found); 1 = fatal error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PROJECTS_ROOT="${DREAM_CLAUDE_PROJECTS_ROOT:-${DREAM_PROJECTS_ROOT:-$HOME/.claude/projects}}"
CODEX_SESSIONS_ROOT="${DREAM_CODEX_SESSIONS_ROOT:-$HOME/.codex/sessions}"
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
SKILL_HOME="${DREAM_SKILL_HOME:-$(dirname "$SCRIPT_DIR")}"
PRIVATE_STATE="$SKILL_HOME/scripts/private-state.sh"
SOURCE="${DREAM_TRANSCRIPT_SOURCE:-all}"
CLAUDE_DEFAULT_WINDOW_START=""
CODEX_DEFAULT_WINDOW_START=""

MODE="default"   # default | since | all
SINCE_DATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --since) MODE="since"; SINCE_DATE="${2:-}"; shift 2 ;;
    --all)   MODE="all";   shift ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    *) echo "find-chats.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

die() { echo "find-chats.sh: $*" >&2; exit 1; }

case "$SOURCE" in
  claude|codex|all) ;;
  "") die "--source requires one of: claude, codex, all" ;;
  *) die "invalid --source '$SOURCE' (expected claude, codex, or all)" ;;
esac

find_claude_files() {
  find "$CLAUDE_PROJECTS_ROOT" -name "*.jsonl" -not -path '*/subagents/*' -print0 2>/dev/null
}

is_codex_subagent_file() {
  local f="$1"
  # Codex sessions are path-based by date, not by thread kind. The session_meta
  # row near the top carries thread_source. A grep check keeps enumeration cheap
  # and degrades safely if older files lack the field.
  head -n 20 "$f" 2>/dev/null | grep -Eq '"thread_source"[[:space:]]*:[[:space:]]*"subagent"'
}

find_codex_files() {
  local f
  while IFS= read -r -d '' f; do
    is_codex_subagent_file "$f" && continue
    printf '%s\0' "$f"
  done < <(find "$CODEX_SESSIONS_ROOT" -name "*.jsonl" -print0 2>/dev/null)
}

find_source_files() {
  case "$SOURCE" in
    claude) find_claude_files ;;
    codex) find_codex_files ;;
    all)
      find_claude_files
      find_codex_files
      ;;
  esac
}

marker_file_for_source() {
  case "$1" in
    claude) echo "$MARKER_DIR/last-run" ;;
    codex) echo "$MARKER_DIR/last-run-codex" ;;
    *) die "internal error: invalid marker source '$1'" ;;
  esac
}

parse_marker_to_ts() {
  local marker_file="$1"
  [ -f "$marker_file" ] || return 1
  local marker_content parsed
  marker_content=$(cat "$marker_file" 2>/dev/null | tr -d '[:space:]')
  if printf '%s' "$marker_content" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    parsed=$(date -j -f "%Y-%m-%d %H:%M:%S" "$marker_content 00:00:00" +%s 2>/dev/null \
      || date -d "$marker_content 00:00:00" +%s 2>/dev/null) || parsed=""
  elif printf '%s' "$marker_content" | grep -qE '^[0-9]+$'; then
    parsed="$marker_content"
  else
    echo "find-chats.sh: WARNING: corrupted marker content '$marker_content' in $marker_file; defaulting to 7-day window" >&2
    return 1
  fi
  [ -n "${parsed:-}" ] && printf '%s' "$parsed" | grep -qE '^[0-9]+$' || return 1
  printf '%s\n' "$parsed"
}

marker_window_start_for_source() {
  local source_name="$1"
  local fallback=$(( now_ts - 7 * 86400 ))
  local parsed
  parsed=$(parse_marker_to_ts "$(marker_file_for_source "$source_name")" 2>/dev/null) || parsed=""
  [ -n "$parsed" ] || parsed="$fallback"
  printf '%s\n' "$parsed"
}

default_marker_window_start() {
  local parsed
  case "$SOURCE" in
    claude|codex)
      parsed=$(marker_window_start_for_source "$SOURCE")
      ;;
    all)
      local claude_ts codex_ts
      claude_ts=$(marker_window_start_for_source claude)
      codex_ts=$(marker_window_start_for_source codex)
      [ "$claude_ts" -le "$codex_ts" ] && parsed="$claude_ts" || parsed="$codex_ts"
      ;;
  esac
  printf '%s\n' "$parsed"
}

file_source() {
  local f="$1"
  case "$f" in
    "$CLAUDE_PROJECTS_ROOT"/*) echo "claude" ;;
    "$CODEX_SESSIONS_ROOT"/*) echo "codex" ;;
    *) return 1 ;;
  esac
}

default_window_start_for_file() {
  local f="$1" source_name
  source_name=$(file_source "$f") || return 1
  case "$source_name" in
    claude) printf '%s\n' "$CLAUDE_DEFAULT_WINDOW_START" ;;
    codex) printf '%s\n' "$CODEX_DEFAULT_WINDOW_START" ;;
    *) return 1 ;;
  esac
}

# ── resolve window start as a Unix timestamp ─────────────────────────────────
now_ts=$(date +%s)

case "$MODE" in
  default)
    window_start=$(default_marker_window_start)
    if [ "$SOURCE" = "all" ]; then
      CLAUDE_DEFAULT_WINDOW_START=$(marker_window_start_for_source claude)
      CODEX_DEFAULT_WINDOW_START=$(marker_window_start_for_source codex)
    fi
    ;;
  since)
    [ -n "$SINCE_DATE" ] || die "--since requires a date argument (YYYY-MM-DD)"
    # Anchor to MIDNIGHT (same wall-clock-fill hazard as the marker branch, C2).
    window_start=$(date -j -f "%Y-%m-%d %H:%M:%S" "$SINCE_DATE 00:00:00" +%s 2>/dev/null \
      || date -d "$SINCE_DATE 00:00:00" +%s 2>/dev/null) \
      || die "cannot parse --since date: $SINCE_DATE"
    ;;
  all)
    # Earliest possible: the oldest .jsonl mtime in the projects root.
    # Find the minimum mtime so we don't emit thousands of empty batches from epoch 0.
    # Fall back to 5 years ago if no files exist yet.
    oldest_ts=""
    while IFS= read -r -d '' f; do
      fmtime=$(stat -c "%Y" "$f" 2>/dev/null || stat -f "%m" "$f" 2>/dev/null || echo 0)
      if [ -z "$oldest_ts" ] || [ "$fmtime" -lt "$oldest_ts" ]; then
        oldest_ts="$fmtime"
      fi
    done < <(find_source_files)
    if [ -n "$oldest_ts" ] && [ "$oldest_ts" -gt 0 ]; then
      window_start="$oldest_ts"
    else
      # No files: default to 5 years ago so we still emit a reasonable BATCH header
      window_start=$(( now_ts - 5 * 365 * 86400 ))
    fi
    ;;
esac

# ── emit weekly batch boundaries + collect paths ─────────────────────────────
# For windows wider than 7 days (--all or old --since), slice into 7-day batches
# so the orchestrator can process and advance the marker one batch at a time.

WINDOW_DAYS=$(( (now_ts - window_start) / 86400 ))
BATCH_SIZE=7  # days per batch

emit_batch() {
  local batch_start="$1" batch_end="$2"
  local bs_fmt be_fmt
  bs_fmt=$(date -r "$batch_start" +%Y-%m-%d 2>/dev/null || date -d "@$batch_start" +%Y-%m-%d)
  be_fmt=$(date -r "$batch_end"   +%Y-%m-%d 2>/dev/null || date -d "@$batch_end"   +%Y-%m-%d)
  echo "BATCH:${bs_fmt}:${be_fmt}"
  # enumerate chats whose mtime falls in [batch_start, batch_end)
  while IFS= read -r -d '' f; do
    fmtime=$(stat -c "%Y" "$f" 2>/dev/null || stat -f "%m" "$f" 2>/dev/null || echo 0)
    if [ "$fmtime" -ge "$batch_start" ] && [ "$fmtime" -lt "$batch_end" ]; then
      if [ "$MODE" = "default" ] && [ "$SOURCE" = "all" ]; then
        source_window_start=$(default_window_start_for_file "$f" 2>/dev/null || echo "$batch_start")
        [ "$fmtime" -lt "$source_window_start" ] && continue
      fi
      # skip --ignore'd chats
      if [ -x "$PRIVATE_STATE" ]; then
        state=$("$PRIVATE_STATE" "$f" 2>/dev/null || echo "record")
      else
        state="record"
      fi
      [ "$state" = "ignore" ] && continue
      echo "$f"
    fi
  # Exclude subagent + workflow transcripts: the human never speaks in them (the
  # "user" turn is a synthetic dispatch prompt), so they carry no persona signal —
  # they are work-output telemetry, explicitly out of scope. Workflows nest under
  # subagents/, so one glob covers both. This is ~73% of all transcripts.
  done < <(find_source_files | sort -z)
}

if [ "$WINDOW_DAYS" -le "$BATCH_SIZE" ]; then
  # Single batch — emit one BATCH header then all paths
  emit_batch "$window_start" "$now_ts"
else
  # Multi-batch: slice from oldest to newest, one week at a time
  cur="$window_start"
  while [ "$cur" -lt "$now_ts" ]; do
    next=$(( cur + BATCH_SIZE * 86400 ))
    [ "$next" -gt "$now_ts" ] && next="$now_ts"
    emit_batch "$cur" "$next"
    cur="$next"
  done
fi
