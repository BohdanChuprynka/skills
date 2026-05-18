#!/usr/bin/env bash
#
# setup.sh — installer for the Codex target of calendar-plan.
#
# Copies skill files into ~/.codex/skills/calendar-plan/ and renders the
# automation.toml into ~/.codex/automations/calendar-plan/ with placeholders
# resolved.
#
# Does NOT manage MCP credentials. Those live in ~/.codex/config.toml and
# are configured per Codex's own model — typically via the desktop app's
# OAuth flow. See docs/SETUP-MCPS.md → "Codex side".

set -euo pipefail

if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_RESET=
fi
heading() { echo; echo "${C_BOLD}${C_BLUE}== $1 ==${C_RESET}"; }
ok()      { echo "  ${C_GREEN}OK${C_RESET}  $*"; }
warn()    { echo "  ${C_YELLOW}WARN${C_RESET}  $*"; }
fail()    { echo "  ${C_RED}FAIL${C_RESET}  $*"; }
skip()    { echo "  ${C_DIM}skip${C_RESET}  $*"; }
read_default() { local p="$1" d="$2" r; read -rp "$p [$d]: " r || true; echo "${r:-$d}"; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLES_DIR="$(cd "$SRC_DIR/../examples" && pwd)"

CODEX_SKILL_DIR="$HOME/.codex/skills/calendar-plan"
CODEX_AUTO_DIR="$HOME/.codex/automations/calendar-plan"

heading "1. Codex prereqs"
if command -v codex >/dev/null 2>&1; then
  ok "codex CLI: $(codex --version 2>&1 | head -1)"
else
  warn "codex CLI not on PATH. Install before testing the automation."
fi

if [[ ! -d "$HOME/.codex" ]]; then
  fail "$HOME/.codex does not exist. Run codex at least once before this installer."
  exit 1
fi

mkdir -p "$CODEX_SKILL_DIR/agents" "$CODEX_AUTO_DIR"

# ============================================================
# 2. Skill files
# ============================================================
heading "2. Install skill files → $CODEX_SKILL_DIR"

cp "$SRC_DIR/SKILL.md"                 "$CODEX_SKILL_DIR/SKILL.md"
ok "  SKILL.md"

cp "$SRC_DIR/agents/openai.example.yaml" "$CODEX_SKILL_DIR/agents/openai.yaml"
ok "  agents/openai.yaml"

if [[ -f "$CODEX_SKILL_DIR/planning-preferences.md" ]]; then
  skip "planning-preferences.md exists — not overwriting"
else
  cp "$EXAMPLES_DIR/planning-preferences.example.md" "$CODEX_SKILL_DIR/planning-preferences.md"
  ok "  planning-preferences.md (from example — edit before first run!)"
fi

# ============================================================
# 3. Resolve automation.toml placeholders
# ============================================================
heading "3. Render automation.toml → $CODEX_AUTO_DIR/automation.toml"

if [[ -f "$CODEX_AUTO_DIR/automation.toml" ]]; then
  read -rp "  $CODEX_AUTO_DIR/automation.toml exists. Overwrite? [y/N] " r
  if [[ ! "$r" =~ ^[Yy]$ ]]; then
    skip "keeping existing automation.toml"
    OVERWRITE_TOML=0
  else
    OVERWRITE_TOML=1
  fi
else
  OVERWRITE_TOML=1
fi

if [[ "$OVERWRITE_TOML" == "1" ]]; then
  CALENDAR_CONTEXT=$(read_default "Absolute path to Calendar Context markdown" "")
  TASK_SOURCE_NAME=$(read_default "Notion task-source page title" "12-Week Planner")
  TIMEZONE=$(read_default "IANA timezone" "America/New_York")
  CRON_HOUR=$(read_default "Cron hour (0-23, local TZ)" "22")
  CODEX_CWD=$(read_default "Codex working dir for the cron run" "$HOME")
  CODEX_MODEL=$(read_default "Codex model" "gpt-5.5")
  CODEX_REASONING=$(read_default "Reasoning effort" "xhigh")

  python3 - <<PYEOF
import pathlib
src = pathlib.Path("$SRC_DIR/automation.example.toml").read_text(encoding="utf-8")
out = (src
    .replace("{{CODEX_SKILL_DIR}}", "$CODEX_SKILL_DIR")
    .replace("{{CODEX_AUTO_DIR}}", "$CODEX_AUTO_DIR")
    .replace("{{CALENDAR_CONTEXT}}", "$CALENDAR_CONTEXT")
    .replace("{{TASK_SOURCE_NAME}}", "$TASK_SOURCE_NAME")
    .replace("{{TIMEZONE}}", "$TIMEZONE")
    .replace("{{CRON_HOUR}}", "$CRON_HOUR")
    .replace("{{CODEX_CWD}}", "$CODEX_CWD")
    .replace("{{CODEX_MODEL}}", "$CODEX_MODEL")
    .replace("{{CODEX_REASONING}}", "$CODEX_REASONING")
)
pathlib.Path("$CODEX_AUTO_DIR/automation.toml").write_text(out, encoding="utf-8")
print("rendered $CODEX_AUTO_DIR/automation.toml")
PYEOF
  chmod 600 "$CODEX_AUTO_DIR/automation.toml"
  ok "  automation.toml (chmod 600)"
fi

# ============================================================
# 4. Memory seed
# ============================================================
heading "4. Memory seed"
if [[ -f "$CODEX_AUTO_DIR/memory.md" ]]; then
  skip "memory.md exists — leaving as is"
else
  cat > "$CODEX_AUTO_DIR/memory.md" <<EOF
# Calendar Plan Automation Memory

Append-only durable observations from \`calendar-plan auto\` runs. Do not replace prior history unless the user explicitly requests compaction.

EOF
  ok "  memory.md"
fi

echo
ok "Codex install complete."
echo "  Skill:      $CODEX_SKILL_DIR"
echo "  Automation: $CODEX_AUTO_DIR"
echo
echo "Next steps:"
echo "  - Edit $CODEX_SKILL_DIR/planning-preferences.md with your real calendar IDs and defaults."
echo "  - Enable Notion / Google Calendar / Gmail MCPs in ~/.codex/config.toml (or via the desktop app)."
echo "  - The cron will be picked up by Codex automatically. Verify with:  codex automations list"
