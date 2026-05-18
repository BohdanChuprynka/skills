#!/usr/bin/env bash
#
# sync.sh — re-render the Codex automation.toml prompt body from prompts/cron-prompt.md.
#
# Use this whenever you edit prompts/cron-prompt.md. The Claude target reads the
# prompt fresh on every run (no sync needed), but Codex bakes the prompt into
# automation.toml at install time — this script updates that baked copy in-place
# without touching the rest of the metadata (rrule, model, status, cwd, etc.).
#
# Usage:
#   bash sync.sh                  # use settings from the existing automation.toml
#   bash sync.sh --dry-run        # render and print, do not write
#   bash sync.sh --help

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$REPO_DIR/prompts/cron-prompt.md"
CODEX_SKILL_DIR="$HOME/.codex/skills/calendar-plan"
CODEX_AUTO_DIR="$HOME/.codex/automations/calendar-plan"
CODEX_TOML="$CODEX_AUTO_DIR/automation.toml"
CLAUDE_SKILL_DIR="$HOME/.claude/skills/calendar-plan"
CLAUDE_SETTINGS="$CLAUDE_SKILL_DIR/config/settings.conf"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's|^# *||'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "FATAL: $PROMPT_FILE not found." >&2
  exit 1
fi
if [[ ! -f "$CODEX_TOML" ]]; then
  echo "FATAL: $CODEX_TOML not found — run codex/setup.sh first." >&2
  exit 1
fi

# Pull placeholder values: prefer Claude settings.conf (same values both sides),
# otherwise fall back to parsing the existing automation.toml.
TIMEZONE="America/New_York"
CRON_HOUR="22"
CALENDAR_CONTEXT=""
TASK_SOURCE_NAME="12-Week Planner"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
  # shellcheck disable=SC1090
  source "$CLAUDE_SETTINGS"
fi

# Render via python (avoids shell-escaping hell)
python3 - <<PYEOF
import pathlib, re, sys

prompt_md = pathlib.Path("$PROMPT_FILE").read_text(encoding="utf-8")
if "\n---\n" in prompt_md:
    body = prompt_md.split("\n---\n", 1)[1].lstrip()
else:
    body = prompt_md

body = (body
    .replace("{{SKILL_DIR}}",        "$CODEX_SKILL_DIR")
    .replace("{{PLANNING_PREFS}}",   "$CODEX_SKILL_DIR/planning-preferences.md")
    .replace("{{MEMORY_FILE}}",      "$CODEX_AUTO_DIR/memory.md")
    .replace("{{CALENDAR_CONTEXT}}", "$CALENDAR_CONTEXT")
    .replace("{{TASK_SOURCE_NAME}}", "$TASK_SOURCE_NAME")
    .replace("{{TIMEZONE}}",         "$TIMEZONE")
    .replace("{{CRON_HOUR}}",        "$CRON_HOUR")
    .replace("{{TARGET_DATE}}",      "")
    .replace("{{MODE}}",             "auto")
    .rstrip()
)

# Escape any triple-quotes inside the body for TOML safety
body_safe = body.replace('"""', '\\"\\"\\"')

# Load existing automation.toml and surgically replace the prompt block.
# Codex writes prompts in two flavors:
#   1. prompt = "Use the …"           (escaped single-line)
#   2. prompt = \"\"\"\n…\n\"\"\"      (triple-quoted multi-line)
# We always rewrite to (2) — cleaner, easier to diff.
toml_path = pathlib.Path("$CODEX_TOML")
text = toml_path.read_text(encoding="utf-8")

triple_pat = re.compile(r'(prompt\s*=\s*""")(.*?)(""")', flags=re.DOTALL)
m = triple_pat.search(text)
if m:
    new_block = f'{m.group(1)}\n{body_safe}\n{m.group(3)}'
    new_text  = text[:m.start()] + new_block + text[m.end():]
else:
    # Try single-line form: prompt = "..."  (handles escapes inside)
    single_pat = re.compile(r'(prompt\s*=\s*")((?:[^"\\\\]|\\\\.)*)(")')
    m = single_pat.search(text)
    if not m:
        print("FATAL: could not find prompt = block in automation.toml", file=sys.stderr)
        sys.exit(1)
    new_block = f'prompt = """\n{body_safe}\n"""'
    new_text  = text[:m.start()] + new_block + text[m.end():]

# Sanity check — no placeholders should remain
leftover = re.findall(r'\{\{[A-Z_]+\}\}', new_block)
if leftover:
    print(f"WARN: unresolved placeholders: {set(leftover)}", file=sys.stderr)

if "$DRY_RUN" == "1":
    print("=== Would write the following to $CODEX_TOML (DRY RUN) ===")
    print()
    print(new_block[:800] + ("\n... (truncated)" if len(new_block) > 800 else ""))
    sys.exit(0)

toml_path.write_text(new_text, encoding="utf-8")
print(f"updated prompt block in $CODEX_TOML ({len(body)} body chars)")
PYEOF

if [[ "$DRY_RUN" == "0" ]]; then
  echo
  echo "Codex automation.toml in sync with prompts/cron-prompt.md"
  echo "Verify:  python3 -c 'import tomllib; tomllib.loads(open(\"$CODEX_TOML\").read()); print(\"valid TOML\")'"
fi
