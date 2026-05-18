#!/usr/bin/env bash
#
# sync.sh — push repo edits into the Codex install.
#
# The Claude target is symlinked to the repo and picks up edits automatically.
# Codex does NOT follow symlinks for skill discovery (all working sibling skills
# are real files), so we copy. This script handles:
#
#   1. copy codex/SKILL.md                  → ~/.codex/skills/calendar-plan/SKILL.md
#   2. copy codex/agents/openai.example.yaml → ~/.codex/skills/calendar-plan/agents/openai.yaml
#   3. re-render prompt body inside ~/.codex/automations/calendar-plan/automation.toml
#      from prompts/cron-prompt.md (preserves rrule, model, status, cwd, etc.)
#
# After running, RESTART Codex — it scans skills at startup only.
#
# Usage:
#   bash sync.sh                  # full sync
#   bash sync.sh --dry-run        # show what would change, write nothing
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

# ============================================================
# 1. Copy stable skill files into Codex install
# ============================================================
copy_one() {  # $1 src, $2 dst, $3 label
  local src="$1" dst="$2" label="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      echo "  unchanged: $label"
    elif [[ -f "$dst" ]]; then
      echo "  would update: $label  ($(wc -c < "$dst") → $(wc -c < "$src") bytes)"
    else
      echo "  would create: $label  ($(wc -c < "$src") bytes)"
    fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "  copied:   $label"
  fi
}

echo "== Codex skill files =="
copy_one "$REPO_DIR/codex/SKILL.md"                  "$CODEX_SKILL_DIR/SKILL.md"            "SKILL.md"
copy_one "$REPO_DIR/codex/agents/openai.example.yaml" "$CODEX_SKILL_DIR/agents/openai.yaml" "agents/openai.yaml"
echo

# ============================================================
# 2. Re-render automation.toml prompt body
# ============================================================
echo "== Codex automation.toml prompt =="

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
  echo "✓ Codex install in sync with repo."
  echo "  RESTART Codex to pick up skill changes (Codex scans skills at startup only)."
fi
