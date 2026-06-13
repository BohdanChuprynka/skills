#!/usr/bin/env bash
#
# calendar-plan.sh — entrypoint for the Claude target of the calendar-plan skill.
#
# Renders the cron prompt with placeholders filled, then invokes:
#   claude --mcp-config <skill>/config/mcp-config.json --strict-mcp-config \
#          --add-dir <obsidian-root> -p "<rendered prompt>"
#
# MCP isolation: only servers in this skill's mcp-config.json load. Daily
# Claude sessions are unaffected.
#
# Usage:
#   bash calendar-plan.sh                       # use settings.conf defaults
#   bash calendar-plan.sh --date 2026-05-19     # plan a specific date
#   bash calendar-plan.sh --mode draft          # draft, do not apply
#   bash calendar-plan.sh --model claude-opus-4-7
#   bash calendar-plan.sh --dry-run             # render prompt, skip LLM call
#   bash calendar-plan.sh --help

set -euo pipefail

# ============================================================
# Skill-dir discovery (portable, works for symlinks)
# ============================================================
SKILL_DIR="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
SCRIPTS_DIR="$SKILL_DIR/scripts"
PROMPTS_DIR="$(cd "$SKILL_DIR/../../prompts" && pwd)"
EXAMPLES_DIR="$(cd "$SKILL_DIR/../../examples" && pwd)"
MEMORY_DIR="$SKILL_DIR/memory"
LOG_DIR="$SKILL_DIR/logs"
mkdir -p "$MEMORY_DIR" "$LOG_DIR"

# PATH boost for cron / launchd / minimal shells (npx must be discoverable)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ============================================================
# Defaults
# ============================================================
MODEL=""
TIMEZONE=""
CRON_HOUR=""
CALENDAR_CONTEXT=""
TASK_SOURCE_NAME=""
# Default to draft (report-only). The SKILL.md contract is "draft first, write on
# approval"; unattended auto-writes must be an explicit opt-in (--mode auto).
DEFAULT_MODE="draft"
EXTRA_ADD_DIRS=""

# Load settings.conf if present
SETTINGS_FILE="$CONFIG_DIR/settings.conf"
if [[ -f "$SETTINGS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SETTINGS_FILE"
fi

# Fallback defaults
: "${MODEL:=claude-sonnet-4-6}"
: "${TIMEZONE:=America/New_York}"
: "${CRON_HOUR:=22}"
: "${DEFAULT_MODE:=draft}"

# ============================================================
# CLI parsing
# ============================================================
TARGET_DATE=""
MODE="$DEFAULT_MODE"
DRY_RUN=0

print_help() {
  cat <<EOF
Usage: calendar-plan.sh [options]

Options:
  --date YYYY-MM-DD       Target date (default: tomorrow in TIMEZONE)
  --mode auto|draft       auto = write safe blocks; draft = report only (default: $DEFAULT_MODE)
  --model ID              Override model (default from settings.conf or claude-sonnet-4-6)
  --dry-run               Render prompt + show command; do not call Claude
  --help, -h              This message

Configuration comes from $SETTINGS_FILE (copy from settings.example.conf).
MCP servers come from $CONFIG_DIR/mcp-config.json (copy from mcp-config.example.json).

Logs:
  $LOG_DIR/run.log
  $LOG_DIR/error.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)   TARGET_DATE="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --model)  MODEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_help >&2; exit 2 ;;
  esac
done

# ============================================================
# Sanity checks
# ============================================================
MCP_CONFIG="$CONFIG_DIR/mcp-config.json"
if [[ ! -f "$MCP_CONFIG" ]]; then
  echo "FATAL: $MCP_CONFIG missing. Run setup.sh first." >&2
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "FATAL: claude CLI not on PATH." >&2
  exit 1
fi
if [[ -z "$CALENDAR_CONTEXT" || ! -f "$CALENDAR_CONTEXT" ]]; then
  echo "WARN: CALENDAR_CONTEXT path missing or empty (was: '$CALENDAR_CONTEXT'). Continuing without it." >&2
fi

# Resolve target date (tomorrow in TIMEZONE if not given)
if [[ -z "$TARGET_DATE" ]]; then
  TARGET_DATE="$(TZ="$TIMEZONE" date -v+1d '+%Y-%m-%d' 2>/dev/null || TZ="$TIMEZONE" date -d 'tomorrow' '+%Y-%m-%d')"
fi

# ============================================================
# Render prompt (placeholder substitution via Python — avoids shell escaping hell)
# ============================================================
MEMORY_FILE="$MEMORY_DIR/memory.md"
[[ -f "$MEMORY_FILE" ]] || cp "$EXAMPLES_DIR/memory.example.md" "$MEMORY_FILE"

PROMPT_FILE="$PROMPTS_DIR/cron-prompt.md"
PROMPT_EXAMPLE="$PROMPTS_DIR/cron-prompt.example.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  if [[ -f "$PROMPT_EXAMPLE" ]]; then
    cp "$PROMPT_EXAMPLE" "$PROMPT_FILE"
    echo "auto-bootstrapped $PROMPT_FILE from example (edit to personalize)" >&2
  else
    echo "FATAL: neither $PROMPT_FILE nor $PROMPT_EXAMPLE exist." >&2
    exit 1
  fi
fi

PLANNING_PREFS="${PLANNING_PREFS:-${XDG_CONFIG_HOME:-$HOME/.config}/calendar-plan/preferences.md}"
if [[ ! -f "$PLANNING_PREFS" ]]; then
  # legacy fallback for installs that still keep prefs inside the skill repo
  if [[ -f "$CONFIG_DIR/planning-preferences.md" ]]; then
    PLANNING_PREFS="$CONFIG_DIR/planning-preferences.md"
  else
    echo "FATAL: $PLANNING_PREFS missing. Copy config/settings.example.conf, run setup.sh, or set PLANNING_PREFS=/path/to/preferences.md." >&2
    exit 1
  fi
fi

TMP_PROMPT="$(mktemp -t calendar-plan-prompt.XXXXXX.md)"
trap 'rm -f "$TMP_PROMPT"' EXIT

python3 "$SCRIPTS_DIR/prep_context.py" \
  --template "$PROMPT_FILE" \
  --out "$TMP_PROMPT" \
  --skill-dir "$SKILL_DIR" \
  --planning-prefs "$PLANNING_PREFS" \
  --memory-file "$MEMORY_FILE" \
  --calendar-context "$CALENDAR_CONTEXT" \
  --task-source-name "$TASK_SOURCE_NAME" \
  --timezone "$TIMEZONE" \
  --cron-hour "$CRON_HOUR" \
  --target-date "$TARGET_DATE" \
  --mode "$MODE"

# Build --add-dir args
ADD_DIRS=()
if [[ -n "$CALENDAR_CONTEXT" && -f "$CALENDAR_CONTEXT" ]]; then
  ADD_DIRS+=(--add-dir "$(dirname "$CALENDAR_CONTEXT")")
fi
for d in $EXTRA_ADD_DIRS; do
  ADD_DIRS+=(--add-dir "$d")
done

# ============================================================
# Run
# ============================================================
echo "==============================================="
echo "  calendar-plan run — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "==============================================="
echo "  skill-dir:    $SKILL_DIR"
echo "  target-date:  $TARGET_DATE ($TIMEZONE)"
echo "  mode:         $MODE"
echo "  model:        $MODEL"
echo "  mcp-config:   $MCP_CONFIG"
echo "  prompt:       $TMP_PROMPT ($(wc -c <"$TMP_PROMPT" | tr -d ' ') bytes)"
echo ""

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY RUN — prompt rendered, claude not invoked."
  echo "Prompt preview:"
  echo "-----------------------------------------------"
  head -40 "$TMP_PROMPT"
  echo "-----------------------------------------------"
  exit 0
fi

RUN_LOG="$LOG_DIR/run-$(date -u '+%Y-%m-%dT%H-%M-%SZ').log"

claude \
  --mcp-config "$MCP_CONFIG" \
  --strict-mcp-config \
  --model "$MODEL" \
  "${ADD_DIRS[@]}" \
  -p "@$TMP_PROMPT" \
  2>&1 | tee "$RUN_LOG"

CLAUDE_EXIT="${PIPESTATUS[0]}"

if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  echo "ERROR: claude exited $CLAUDE_EXIT — see $RUN_LOG" >&2
  exit "$CLAUDE_EXIT"
fi

# Append a memory entry summarising this run
python3 "$SCRIPTS_DIR/apply_log.py" \
  --memory-file "$MEMORY_FILE" \
  --run-log "$RUN_LOG" \
  --target-date "$TARGET_DATE" \
  --mode "$MODE" \
  --timezone "$TIMEZONE" || echo "WARN: apply_log.py failed; memory not updated."

echo ""
echo "run complete. log: $RUN_LOG"
