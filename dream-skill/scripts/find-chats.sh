#!/usr/bin/env bash
# find-chats.sh — enumerate ~/.claude/projects/**/*.jsonl files whose mtime
# falls inside the requested time window, skip --ignore'd chats, emit weekly
# batch boundaries for large windows.
#
# Usage:
#   find-chats.sh [--since <YYYY-MM-DD>] [--all]
#
# Environment overrides (for tests):
#   DREAM_PROJECTS_ROOT  — replaces ~/.claude/projects
#   DREAM_MARKER_DIR     — dir holding the `last-run` marker file
#   DREAM_SKILL_HOME     — plugin root (for scripts/private-state.sh)
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
PROJECTS_ROOT="${DREAM_PROJECTS_ROOT:-$HOME/.claude/projects}"
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
MARKER_FILE="$MARKER_DIR/last-run"
SKILL_HOME="${DREAM_SKILL_HOME:-$(dirname "$SCRIPT_DIR")}"
PRIVATE_STATE="$SKILL_HOME/scripts/private-state.sh"

MODE="default"   # default | since | all
SINCE_DATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --since) MODE="since"; SINCE_DATE="${2:-}"; shift 2 ;;
    --all)   MODE="all";   shift ;;
    *) echo "find-chats.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

die() { echo "find-chats.sh: $*" >&2; exit 1; }

# ── resolve window start as a Unix timestamp ─────────────────────────────────
now_ts=$(date +%s)

case "$MODE" in
  default)
    if [ -f "$MARKER_FILE" ]; then
      # marker exists: start = marker content (YYYY-MM-DD or epoch integer)
      marker_content=$(cat "$MARKER_FILE" 2>/dev/null | tr -d '[:space:]')
      if printf '%s' "$marker_content" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        # clean YYYY-MM-DD
        # Anchor to MIDNIGHT — BSD `date -j -f "%Y-%m-%d"` fills H:M:S from the wall
        # clock, which would drift window_start to ~now's time-of-day and silently
        # drop early-in-day chats on the boundary date (see REVIEW-2026-06-04 C2).
        window_start=$(date -j -f "%Y-%m-%d %H:%M:%S" "$marker_content 00:00:00" +%s 2>/dev/null \
          || date -d "$marker_content 00:00:00" +%s 2>/dev/null) \
          || window_start=""
      elif printf '%s' "$marker_content" | grep -qE '^[0-9]+$'; then
        # clean epoch integer
        window_start="$marker_content"
      else
        # corrupted marker — NEVER fall back to epoch-0/all-history; use 7-day safe default
        echo "find-chats.sh: WARNING: corrupted marker content '$marker_content'; defaulting to 7-day window" >&2
        window_start=""
      fi
      # If parse failed or empty, fall back to 7 days (never epoch-0)
      if [ -z "${window_start:-}" ] || ! printf '%s' "${window_start:-}" | grep -qE '^[0-9]+$'; then
        window_start=$(( now_ts - 7 * 86400 ))
      fi
    else
      # No marker: default to last 7 days
      window_start=$(( now_ts - 7 * 86400 ))
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
    done < <(find "$PROJECTS_ROOT" -name "*.jsonl" -not -path '*/subagents/*' -print0 2>/dev/null)
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
  done < <(find "$PROJECTS_ROOT" -name "*.jsonl" -not -path '*/subagents/*' -print0 2>/dev/null | sort -z)
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
