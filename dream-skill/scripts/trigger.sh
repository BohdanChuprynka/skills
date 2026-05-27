#!/usr/bin/env bash
# dream-skill SessionEnd trigger.
# Fires from Claude Code's SessionEnd hook (registered in hooks/hooks.json).
# Counts user-turn messages in the transcript; if ≥THRESHOLD, dispatches
# headless `claude -p "/dream-skill --auto <transcript>"` in the background.
# Stays fire-and-forget: never blocks shutdown, never errors visibly.

set -euo pipefail

# --- config -------------------------------------------------------------
THRESHOLD="${DREAM_THRESHOLD:-10}"
LOG_FILE="${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}"

# --- robust exit handling -----------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE" 2>/dev/null || true
}

on_exit() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "ERROR rc=$rc"
  fi
  exit 0  # never propagate non-zero to Claude Code
}
trap on_exit EXIT

# --- resolve transcript -------------------------------------------------
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  log "SKIP no-transcript path='$TRANSCRIPT'"
  exit 0
fi

# --- count user-turn messages -------------------------------------------
USER_MSGS=$(grep -c '"role":"user"' "$TRANSCRIPT" 2>/dev/null || echo 0)

if [ "$USER_MSGS" -lt "$THRESHOLD" ]; then
  log "SKIP below-threshold count=$USER_MSGS threshold=$THRESHOLD transcript=$TRANSCRIPT"
  exit 0
fi

log "DISPATCH count=$USER_MSGS threshold=$THRESHOLD transcript=$TRANSCRIPT"

# --- test stub: skip the actual headless spawn --------------------------
if [ "${DREAM_DISPATCH_STUB:-0}" = "1" ]; then
  exit 0
fi

# --- spawn headless invocation (background, fire-and-forget) ------------
if ! command -v claude >/dev/null 2>&1; then
  log "ERROR claude-cli-missing"
  exit 0
fi

nohup claude -p "/dream-skill --auto $TRANSCRIPT" \
  >> "$(dirname "$LOG_FILE")/headless.log" 2>&1 &
disown
log "SPAWNED pid=$!"
exit 0
