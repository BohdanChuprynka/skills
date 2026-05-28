#!/usr/bin/env bash
# dream-skill SessionEnd trigger.
# Fires from Claude Code's SessionEnd hook (registered in hooks/hooks.json).
# Counts user-turn messages in the transcript; if ≥THRESHOLD, dispatches
# headless `claude -p "/dream-skill --auto <transcript>"` in the background.
# Stays fire-and-forget: never blocks shutdown, never errors visibly.
#
# Concurrency safety: per-transcript lock prevents duplicate dispatch when
# the same conversation is closed from multiple windows (e.g., after /resume).

set -euo pipefail

# --- config -------------------------------------------------------------
THRESHOLD="${DREAM_THRESHOLD:-5}"
LOG_FILE="${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}"
LOCK_DIR="${DREAM_LOCK_DIR:-$HOME/.claude/dream-skill/.locks}"
LOCK_TTL_SEC="${DREAM_LOCK_TTL_SEC:-600}"  # 10 min — within window, suppress dup dispatch

# --- robust exit handling -----------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" "$LOCK_DIR" 2>/dev/null || true

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE" 2>/dev/null || true
}

on_exit() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "ERROR source=trigger code=$rc msg=trap-fired"
  fi
  exit 0  # never propagate non-zero to Claude Code
}
trap on_exit EXIT

# --- resolve transcript -------------------------------------------------
# Claude Code SessionEnd hooks pass JSON on stdin:
#   {"session_id":"...","transcript_path":"...","cwd":"...","reason":"..."}
# We also accept CLAUDE_TRANSCRIPT_PATH env var as a fallback (tests + manual).
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"
REASON=""

# Try stdin JSON if env var empty AND stdin is piped (not a tty)
if [ -z "$TRANSCRIPT" ] && [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
  if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
    TRANSCRIPT=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
    REASON=$(echo "$STDIN_JSON" | jq -r '.reason // empty' 2>/dev/null || true)
  fi
fi

# Clearer SKIP buckets: no path vs path-but-file-missing
if [ -z "$TRANSCRIPT" ]; then
  log "SKIP no-path-provided"
  exit 0
fi

if [ ! -f "$TRANSCRIPT" ]; then
  log "SKIP file-not-found path='$TRANSCRIPT'"
  exit 0
fi

# Optional: skip on certain reasons (clear/prompt_input_exit = user keeps working)
case "$REASON" in
  clear|prompt_input_exit)
    log "SKIP reason=$REASON"
    exit 0
    ;;
esac

# --- count user-turn messages -------------------------------------------
USER_MSGS=$(grep -c '"role":"user"' "$TRANSCRIPT" 2>/dev/null || echo 0)

if [ "$USER_MSGS" -lt "$THRESHOLD" ]; then
  log "SKIP below-threshold count=$USER_MSGS threshold=$THRESHOLD"
  exit 0
fi

# --- per-transcript dedupe lock -----------------------------------------
# Hash the transcript path; if a recent lock exists for it, suppress dispatch.
# Solves: user closes same chat from two windows (/resume scenario) → only
# the first close triggers a real run.
if command -v shasum >/dev/null 2>&1; then
  TRANSCRIPT_HASH=$(printf '%s' "$TRANSCRIPT" | shasum -a 1 | awk '{print $1}')
else
  TRANSCRIPT_HASH=$(printf '%s' "$TRANSCRIPT" | cksum | awk '{print $1}')
fi
LOCK_FILE="$LOCK_DIR/$TRANSCRIPT_HASH"

if [ -f "$LOCK_FILE" ]; then
  # Cross-platform mtime: BSD stat vs GNU stat
  LOCK_MTIME=$(stat -f %m "$LOCK_FILE" 2>/dev/null || stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$((NOW - LOCK_MTIME))
  if [ "$AGE" -lt "$LOCK_TTL_SEC" ]; then
    log "SKIP duplicate-dispatch age=${AGE}s ttl=${LOCK_TTL_SEC}s transcript=$TRANSCRIPT"
    exit 0
  fi
fi

# Take the lock (touches the file with current timestamp)
touch "$LOCK_FILE"

log "DISPATCH count=$USER_MSGS threshold=$THRESHOLD transcript=$TRANSCRIPT reason=${REASON:-unknown}"

# --- test stub: skip the actual headless spawn --------------------------
if [ "${DREAM_DISPATCH_STUB:-0}" = "1" ]; then
  exit 0
fi

# --- spawn headless invocation (background, fire-and-forget) ------------
if ! command -v claude >/dev/null 2>&1; then
  log "ERROR source=trigger code=127 msg=claude-cli-missing"
  exit 0
fi

# Resolve the plugin/scripts dir so the headless LLM has unambiguous paths.
# When triggered via /plugin install: $CLAUDE_PLUGIN_ROOT is set.
# When triggered via manual settings.json hook: derive from this script's own location.
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-}"
if [ -n "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$SCRIPTS_DIR/scripts"
else
  SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

DREAM_HOME="${DREAM_HOME:-$HOME/.claude/dream-skill}"

# Export unambiguous paths for the headless LLM to use in SKILL.md.
export DREAM_SCRIPTS_DIR="$SCRIPTS_DIR"
export DREAM_HOME
export DREAM_CONFIG="${DREAM_CONFIG:-$DREAM_HOME/config.toml}"
export DREAM_QUEUE_FILE="${DREAM_QUEUE_FILE:-$DREAM_HOME/queue/pending.md}"
export DREAM_DAILY_LOG="$DREAM_HOME/log/$(date -u +%Y-%m-%d).md"
export DREAM_UNDO_LOG="$DREAM_HOME/undo/$(date -u +%Y-%m-%d).jsonl"
export DREAM_ERROR_LOG="$DREAM_HOME/error.log"
export DREAM_TRANSCRIPT="$TRANSCRIPT"

# Pin model: Haiku 4.5 is sufficient for the dream-skill classifier+router
# task (pattern matching + tool calls, no deep reasoning). ~30x cheaper
# than Opus, ~10x cheaper than Sonnet at default effort. Override via
# $DREAM_MODEL if you want Sonnet/Opus for higher-quality classification.
MODEL="${DREAM_MODEL:-claude-haiku-4-5}"

# Background wrapper: spawn claude -p, await exit, append COMPLETED/ERROR
# to trigger.log. Outer `nohup ... &` keeps trigger.sh fire-and-forget
# (it returns immediately). Inner block is the wait-and-report logic.
# No notifications anywhere — logs only.
nohup bash -c "
  claude -p \\
    --model '$MODEL' \\
    --dangerously-skip-permissions \\
    '/dream-skill --auto $TRANSCRIPT' \\
    >> '$(dirname "$LOG_FILE")/headless.log' 2>&1
  RC=\$?
  TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ \$RC -ne 0 ]; then
    echo \"\$TS ERROR source=claude-p code=\$RC transcript=$TRANSCRIPT\" >> '$LOG_FILE'
  else
    echo \"\$TS COMPLETED source=claude-p transcript=$TRANSCRIPT\" >> '$LOG_FILE'
  fi
" >/dev/null 2>&1 &
disown

log "SPAWNED pid=$! model=$MODEL scripts=$SCRIPTS_DIR transcript=$TRANSCRIPT"
exit 0
