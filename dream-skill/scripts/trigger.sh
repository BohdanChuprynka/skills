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
LOCK_DIR="${DREAM_LOCK_DIR:-$HOME/.claude/dream-skill/.locks}"  # per-transcript seen-count state
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

# First user prompt for a session id, from history.jsonl — the basis of the
# title Claude Code shows in its resume picker. Single line, truncated. Empty
# (no title line) when history/jq is unavailable or the id has no prompt.
dream_chat_title() {
  local sid="$1" hist title
  hist="${DREAM_HISTORY_FILE:-$HOME/.claude/history.jsonl}"
  [ -n "$sid" ] && [ -f "$hist" ] && command -v jq >/dev/null 2>&1 || return 0
  # First prompt that is real typed text — skip Claude Code's paste/image
  # placeholders ("[Pasted text #1 +3 lines]", "[Image #1]"); they make useless titles.
  title=$(grep -F "\"sessionId\":\"$sid\"" "$hist" 2>/dev/null \
          | jq -r 'select(((.display // "") | length) > 0 and ((.display // "") | test("^\\[(Pasted|Image)") | not)) | .display' 2>/dev/null \
          | head -1 || true)
  title=$(printf '%s' "$title" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//')
  [ "${#title}" -gt 70 ] && title="${title:0:70}…"
  printf '%s' "$title"
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
                 --title "$(dream_chat_title "$(basename "${TRANSCRIPT%.jsonl}")")" \
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

# --- count GENUINE user-turn messages -----------------------------------
# A plain `grep -c '"role":"user"'` badly overcounts: tool-call RESULTS and
# system-injected records (task-notifications, /command stdout, caveats) are
# ALSO stored with role:user, so a chat with 3 typed messages can report 15.
# That inflates both the threshold check AND the count-delta gate below — a
# system record appended on /resume (without the user typing) would look like
# new content and wrongly re-dispatch. Count only what the user actually typed:
# role:user, not isMeta/compactSummary, content is real text (a string or a
# text block) that is neither a tool_result nor a bare system-tag injection.
# Handles both the nested real Claude Code shape and the flat test-fixture shape.
# A leading <system-reminder> is a harness PREFIX on a genuine turn, so it is
# intentionally NOT in the skip list (standalone reminders are isMeta and drop out).
# jq missing → fall back to the coarse grep (overcounts, but stays monotonic).
if command -v jq >/dev/null 2>&1; then
  USER_MSGS=$(jq -rR '
    fromjson?
    | (.message.content // .content) as $c
    | ((.message.role // .role) // "") as $r
    | ((.isMeta // false) or (.isCompactSummary // false)) as $meta
    | select($r == "user" and ($meta | not) and (
        ($c | type) as $t
        | if $t == "string" then
            (($c | gsub("[[:space:]]";"")) | length) > 0
            and ($c | test("^[[:space:]]*<(task-notification|local-command|command-name|command-message|command-args|command-stdout|command-output)") | not)
          elif $t == "array" then
            ([ $c[] | select(.type? == "tool_result") ] | length) == 0
            and ([ $c[] | select((.type? == "text")
                     and ((.text // "") | gsub("[[:space:]]";"") | length) > 0
                     and ((.text // "") | test("^[[:space:]]*<(task-notification|local-command|command-name|command-message|command-args|command-stdout|command-output)") | not)) ] | length) > 0
          else false end))
    | "x"' "$TRANSCRIPT" 2>/dev/null | grep -c 'x') || USER_MSGS=0
else
  USER_MSGS=$(grep -c '"role":"user"' "$TRANSCRIPT" 2>/dev/null) || USER_MSGS=0
fi
case "$USER_MSGS" in ''|*[!0-9]*) USER_MSGS=0 ;; esac

if [ "$USER_MSGS" -lt "$THRESHOLD" ]; then
  log "SKIP below-threshold count=$USER_MSGS threshold=$THRESHOLD"
  "$REPORT_SH" --status skipped --chat "$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")" \
               --title "$(dream_chat_title "$(basename "${TRANSCRIPT%.jsonl}")")" \
               --reason "below-threshold ($USER_MSGS user messages)" 2>/dev/null || true
  exit 0
fi

# --- per-transcript new-content gate ------------------------------------
# Ingest only when the conversation CHANGED since the last dispatch. We store
# the user-message count (keyed by the resolved transcript path) and compare on
# the next close. Resuming a chat and closing it WITHOUT typing leaves the count
# identical -> skip; typing any message (even "hello") changes it -> dispatch,
# no matter how soon after the last run. Same content closed from two windows is
# the same count -> one dispatch, which is what the old time-lock guarded.
# Compare with != (not >): if the counting METHOD ever changes scale, a count
# stored by the old method won't match the new one, so the chat re-dispatches
# once and re-baselines instead of getting stuck skipping forever. Within a
# single transcript the count only grows, so for normal use != behaves like >.
if command -v shasum >/dev/null 2>&1; then
  TRANSCRIPT_HASH=$(printf '%s' "$TRANSCRIPT" | shasum -a 1 | awk '{print $1}')
else
  TRANSCRIPT_HASH=$(printf '%s' "$TRANSCRIPT" | cksum | awk '{print $1}')
fi
SEEN_FILE="$LOCK_DIR/$TRANSCRIPT_HASH"

PREV_MSGS=$(cat "$SEEN_FILE" 2>/dev/null || echo 0)
case "$PREV_MSGS" in ''|*[!0-9]*) PREV_MSGS=0 ;; esac

if [ "$USER_MSGS" -eq "$PREV_MSGS" ]; then
  log "SKIP no-new-messages count=$USER_MSGS prev=$PREV_MSGS transcript=$TRANSCRIPT"
  exit 0
fi

# Record the count we are dispatching at, so the next close can compare.
echo "$USER_MSGS" > "$SEEN_FILE"

log "DISPATCH count=$USER_MSGS prev=$PREV_MSGS threshold=$THRESHOLD transcript=$TRANSCRIPT reason=${REASON:-unknown}"

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
export DREAM_CHAT_TITLE="$(dream_chat_title "$(basename "${TRANSCRIPT%.jsonl}")")"
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
