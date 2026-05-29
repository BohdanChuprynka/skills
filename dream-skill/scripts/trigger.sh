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
THRESHOLD="${DREAM_THRESHOLD:-1}"  # dispatch on any session with >=1 user message; raise via DREAM_THRESHOLD
LOG_FILE="${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}"
LOCK_DIR="${DREAM_LOCK_DIR:-$HOME/.claude/dream-skill/.locks}"
LOCK_TTL_SEC="${DREAM_LOCK_TTL_SEC:-600}"  # 10 min — within window, suppress dup dispatch
RESOLVE_WINDOW_SEC="${DREAM_RESOLVE_WINDOW_SEC:-3600}"  # compaction-continuation → root recency guard (1h)

# report.sh path (resolved early so the skip branches below can call it).
REPORT_SH="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}"
REPORT_SH="${REPORT_SH:-$(cd "$(dirname "$0")" && pwd)}/report.sh"

# Chat label "<first8 of uuid> (<project>)" for vault report entries.
dream_chat_label() {
  local tpath="$1" cwd="$2" id proj
  id="$(basename "${tpath%.jsonl}")"; id="${id:0:8}"
  if [ -n "$cwd" ]; then proj="$(basename "$cwd")"; else proj="$(basename "$(dirname "$tpath")")"; fi
  printf '%s (%s)' "${id:-unknown}" "${proj:-?}"
}

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
CWD=""

# Try stdin JSON if env var empty AND stdin is piped (not a tty)
if [ -z "$TRANSCRIPT" ] && [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
  if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
    TRANSCRIPT=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
    REASON=$(echo "$STDIN_JSON" | jq -r '.reason // empty' 2>/dev/null || true)
    CWD=$(echo "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null || true)
  fi
fi

# Clearer SKIP buckets: no path vs path-but-file-missing
if [ -z "$TRANSCRIPT" ]; then
  log "SKIP no-path-provided"
  exit 0
fi

if [ ! -f "$TRANSCRIPT" ]; then
  # The path may belong to a compaction/resume CONTINUATION. Claude Code gives
  # each continuation a fresh session_id but keeps appending the conversation to
  # the ROOT session's .jsonl, so the continuation's SessionEnd fires with a
  # path that never materializes. Without recovery, every long conversation that
  # compacts loses all signal added after its first dispatch. Resolve to the
  # live root transcript instead.
  RESOLVED=""
  CONT_DIR="${TRANSCRIPT%.jsonl}"
  CONT_UUID="$(basename "$CONT_DIR")"
  PROJ_DIR="$(dirname "$TRANSCRIPT")"
  # Compaction signature: a sibling per-session directory (holding tool-results)
  # exists even though the .jsonl does not. Absent that directory there is
  # genuinely nothing to recover — fall through to the original skip.
  if [ -d "$CONT_DIR" ] && [ -d "$PROJ_DIR" ]; then
    NOW=$(date +%s)
    # Scan newest-first: the live root that just compacted is the most recently
    # written .jsonl. Require both (a) recency and (b) that the candidate
    # actually references this continuation's uuid, so concurrent unrelated
    # sessions and stale incidental mentions are never mistaken for the root.
    while IFS= read -r cand; do
      [ -f "$cand" ] || continue
      cand_mtime=$(stat -f %m "$cand" 2>/dev/null || stat -c %Y "$cand" 2>/dev/null || echo 0)
      [ $((NOW - cand_mtime)) -le "$RESOLVE_WINDOW_SEC" ] || continue
      if grep -qF "$CONT_UUID" "$cand" 2>/dev/null; then
        RESOLVED="$cand"
        break
      fi
    done < <(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null || true)
  fi

  if [ -n "$RESOLVED" ]; then
    log "RESOLVED continuation=$CONT_UUID root=$(basename "$RESOLVED")"
    TRANSCRIPT="$RESOLVED"
  else
    log "SKIP file-not-found path='$TRANSCRIPT'"
    "$REPORT_SH" --status skipped --chat "$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")" \
                 --reason "no transcript found" 2>/dev/null || true
    exit 0
  fi
fi

# --- recursion guard: never re-process our own headless auto-runs -------
# A headless `claude -p "/dream-skill --auto X"` spawns its OWN session. When
# that session ends, Claude Code fires THIS hook again with the run's own
# transcript — which would re-dispatch forever: a self-perpetuating cascade
# that burns model quota every ~30s and even spreads across projects.
# Two independent skips:
#   1. DREAM_SKILL_HEADLESS env marker set on the spawned run (see below); its
#      SessionEnd inherits it.
#   2. The injected SKILL.md signature at the head of the transcript — a
#      headless run's first message IS the skill prompt — as a fallback in
#      case the hook does not inherit the spawned process's environment.
if [ "${DREAM_SKILL_HEADLESS:-0}" = "1" ]; then
  log "SKIP recursive-headless reason=env-marker transcript=$TRANSCRIPT"
  exit 0
fi
if head -c 8000 "$TRANSCRIPT" 2>/dev/null | grep -qE 'Persona-model sync for an Obsidian vault|/dream-skill --auto'; then
  log "SKIP recursive-headless reason=skill-signature transcript=$TRANSCRIPT"
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
# grep -c prints "0" AND exits 1 on zero matches; capturing through `|| echo 0`
# would append a second line ("0\n0") and break the integer compare below.
# Capture the count, then normalize a non-zero exit to a clean integer.
USER_MSGS=$(grep -c '"role":"user"' "$TRANSCRIPT" 2>/dev/null) || USER_MSGS=0

if [ "$USER_MSGS" -lt "$THRESHOLD" ]; then
  log "SKIP below-threshold count=$USER_MSGS threshold=$THRESHOLD"
  "$REPORT_SH" --status skipped --chat "$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")" \
               --reason "below-threshold ($USER_MSGS user messages)" 2>/dev/null || true
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
export DREAM_CHAT_LABEL="$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")"
export DREAM_LOG  # explicit export so the headless skill can append COMPLETED/ERROR markers
# Recursion marker: the spawned run's OWN SessionEnd fires this hook again.
# This var lets that invocation recognize itself as a headless auto-run and
# skip (see recursion guard above), belt-and-suspenders with the signature check.
export DREAM_SKILL_HEADLESS=1

# Pin model: Haiku 4.5 is sufficient for the dream-skill classifier+router
# task (pattern matching + tool calls, no deep reasoning). ~30x cheaper
# than Opus, ~10x cheaper than Sonnet at default effort. Override via
# $DREAM_MODEL if you want Sonnet/Opus for higher-quality classification.
MODEL="${DREAM_MODEL:-claude-haiku-4-5}"

# Background wrapper: spawn claude -p, await exit, append COMPLETED/ERROR
# to trigger.log. Outer `nohup ... &` keeps trigger.sh fire-and-forget
# (it returns immediately). Inner block is the wait-and-report logic.
# No notifications anywhere — logs only.
#
# Hardening (defense-in-depth with the recursion guard above):
#   --no-session-persistence : the headless run writes NO transcript to disk, so
#       its SessionEnd has nothing to recurse on (kills the cascade at the source)
#       and no junk transcripts pile up. Valid only with --print, which we use.
#   --strict-mcp-config      : auto mode never calls MCP tools; don't load the
#       user's Notion/Gmail/Calendar servers — faster run, smaller surface.
nohup bash -c "
  claude -p \\
    --model '$MODEL' \\
    --dangerously-skip-permissions \\
    --no-session-persistence \\
    --strict-mcp-config \\
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
