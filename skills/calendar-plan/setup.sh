#!/usr/bin/env bash
#
# setup.sh — interactive wizard for the Claude target of calendar-plan.
#
# Walks the user through:
#   1. Prereqs (claude CLI, node/npx, python3)
#   2. settings.conf (model, TZ, cron hour, Calendar Context path, task source name)
#   3. planning-preferences.md (copies from examples/, opens in $EDITOR for edits)
#   4. mcp-config.json (per-MCP credential prompts — Notion token, Gmail/GCal OAuth paths, FS root)
#   5. memory.md seed (copies example)
#   6. doctor.sh health check

set -euo pipefail

# colors
if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_RESET=
fi
heading() { echo; echo "${C_BOLD}${C_BLUE}== $1 ==${C_RESET}"; }
say()     { echo "  $*"; }
ok()      { echo "  ${C_GREEN}OK${C_RESET}  $*"; }
warn()    { echo "  ${C_YELLOW}WARN${C_RESET}  $*"; }
fail()    { echo "  ${C_RED}FAIL${C_RESET}  $*"; }
skip()    { echo "  ${C_DIM}skip${C_RESET}  $*"; }

read_default() {  # $1 prompt, $2 default
  local p="$1" d="$2" r
  if [[ -n "$d" ]]; then
    read -rp "$p [$d]: " r || true
    echo "${r:-$d}"
  else
    read -rp "$p: " r || true
    echo "$r"
  fi
}
read_yn() {  # $1 prompt, $2 default (y|n)
  local p="$1" d="$2" r
  read -rp "$p [${d}/$( [[ $d == y ]] && echo n || echo y )]: " r || true
  REPLY="${r:-$d}"
  [[ "$REPLY" =~ ^[Yy]$ ]] && REPLY=y || REPLY=n
}

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
EXAMPLES_DIR="$(cd "$SKILL_DIR/../../examples" && pwd)"
MEMORY_DIR="$SKILL_DIR/memory"
mkdir -p "$CONFIG_DIR" "$MEMORY_DIR"

# ============================================================
# CLI flags
# ============================================================
MCP_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --mcp)       MCP_ONLY=1 ;;
    --help|-h)
      cat <<EOF
Usage: setup.sh [--mcp]

Default: walk through the full wizard (prereqs, settings, planning prefs, MCPs, memory, doctor).

  --mcp     Re-run ONLY the MCP credential wizard (step 4). Useful after rotating tokens.
  --help    This message.
EOF
      exit 0
      ;;
  esac
done

if [[ $MCP_ONLY -eq 1 ]]; then
  heading "MCP-only wizard"
  say "Skipping prereqs / settings / planning-preferences / memory — re-running MCP step only."
fi

# ============================================================
# Step 1 — prereqs
# ============================================================
[[ $MCP_ONLY -eq 1 ]] || heading "1. Prereqs"
if [[ $MCP_ONLY -eq 0 ]]; then

if command -v claude >/dev/null 2>&1; then
  ok "claude CLI: $(claude --version 2>&1 | head -1)"
else
  fail "claude CLI not on PATH. Install: https://docs.claude.com/claude-code"
  exit 1
fi

if command -v npx >/dev/null 2>&1; then
  ok "npx: $(npx --version)"
else
  fail "npx not on PATH. Install Node.js: https://nodejs.org/"
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  ok "python3: $(python3 --version)"
else
  fail "python3 not on PATH."
  exit 1
fi

fi  # end Step 1 (MCP_ONLY guard)

# ============================================================
# Step 2 — settings.conf
# ============================================================
if [[ $MCP_ONLY -eq 0 ]]; then
heading "2. Settings (model, timezone, cron hour, Calendar Context)"

SETTINGS="$CONFIG_DIR/settings.conf"
if [[ -f "$SETTINGS" ]]; then
  read_yn "Found existing $SETTINGS. Overwrite?" "n"
  if [[ "$REPLY" == "n" ]]; then skip "keeping existing settings.conf"; SETTINGS=""; fi
fi

if [[ -n "$SETTINGS" ]]; then
  MODEL=$(read_default "Anthropic model" "claude-sonnet-4-6")
  TIMEZONE=$(read_default "IANA timezone" "America/New_York")
  CRON_HOUR=$(read_default "Cron hour (0-23, local TZ)" "22")
  CALENDAR_CONTEXT=$(read_default "Absolute path to Calendar Context markdown page" "")
  TASK_SOURCE_NAME=$(read_default "Notion task-source page title" "12-Week Planner")
  EXTRA_ADD_DIRS=$(read_default "Extra --add-dir paths (space-separated, optional)" "")
  cat > "$SETTINGS" <<EOF
MODEL="$MODEL"
TIMEZONE="$TIMEZONE"
CRON_HOUR="$CRON_HOUR"
CALENDAR_CONTEXT="$CALENDAR_CONTEXT"
TASK_SOURCE_NAME="$TASK_SOURCE_NAME"
DEFAULT_MODE="auto"
EXTRA_ADD_DIRS="$EXTRA_ADD_DIRS"
EOF
  chmod 600 "$SETTINGS"
  ok "wrote $SETTINGS (chmod 600)"
fi

fi  # end Step 2 (MCP_ONLY guard)

# ============================================================
# Step 3 — planning-preferences.md
# ============================================================
if [[ $MCP_ONLY -eq 0 ]]; then
heading "3. planning-preferences.md"

PREFS="$CONFIG_DIR/planning-preferences.md"
if [[ -f "$PREFS" ]]; then
  skip "$PREFS already exists; not overwriting"
else
  cp "$EXAMPLES_DIR/planning-preferences.example.md" "$PREFS"
  chmod 600 "$PREFS"
  ok "copied example to $PREFS (chmod 600)"
  say "edit it now to set calendar IDs, Notion page slug, daily defaults, calendar routing"
  say "open with: \$EDITOR $PREFS"
fi

fi  # end Step 3 (MCP_ONLY guard)

# ============================================================
# Step 4 — MCP integrations (always runs, including under --mcp)
# ============================================================
heading "4. MCP integrations (tokens stored in mcp-config.json, chmod 600)"

MCP_CONFIG="$CONFIG_DIR/mcp-config.json"
if [[ -f "$MCP_CONFIG" ]]; then
  read_yn "Found existing $MCP_CONFIG. Overwrite?" "n"
  [[ "$REPLY" == "n" ]] && { skip "keeping existing mcp-config.json"; MCP_CONFIG=""; }
fi

if [[ -n "$MCP_CONFIG" ]]; then
  say "You'll be prompted for each MCP. Press Enter to skip an integration."
  echo

  NOTION_TOKEN=$(read_default "Notion integration token (ntn_...)" "")
  GCAL_CREDS=$(read_default "Absolute path to Google Calendar OAuth credentials.json" "")
  GMAIL_OAUTH=$(read_default "Absolute path to Gmail OAuth credentials.json" "")
  GMAIL_TOKEN=$(read_default "Absolute path to Gmail token.json" "")
  FS_ROOT=$(read_default "Absolute path to Obsidian vault root (for filesystem MCP)" "")

  SERVERS=""
  if [[ -n "$NOTION_TOKEN" ]]; then
    SERVERS+="
    \"notion\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"@notionhq/notion-mcp-server\"],
      \"env\": {
        \"OPENAPI_MCP_HEADERS\": \"{\\\"Authorization\\\":\\\"Bearer ${NOTION_TOKEN}\\\",\\\"Notion-Version\\\":\\\"2022-06-28\\\"}\"
      }
    },"
    ok "  notion configured"
  fi
  if [[ -n "$GCAL_CREDS" ]]; then
    SERVERS+="
    \"google-calendar\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"@cocal/google-calendar-mcp\"],
      \"env\": { \"GOOGLE_OAUTH_CREDENTIALS\": \"${GCAL_CREDS}\" }
    },"
    ok "  google-calendar configured"
  fi
  if [[ -n "$GMAIL_OAUTH" && -n "$GMAIL_TOKEN" ]]; then
    SERVERS+="
    \"gmail\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"@gongrzhe/server-gmail-autoauth-mcp\"],
      \"env\": {
        \"GMAIL_OAUTH_PATH\": \"${GMAIL_OAUTH}\",
        \"GMAIL_CREDENTIALS_PATH\": \"${GMAIL_TOKEN}\"
      }
    },"
    ok "  gmail configured"
  fi
  if [[ -n "$FS_ROOT" ]]; then
    SERVERS+="
    \"filesystem-vault\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"${FS_ROOT}\"]
    },"
    ok "  filesystem-vault configured (${FS_ROOT})"
  fi
  SERVERS="${SERVERS%,}"

  cat > "$MCP_CONFIG" <<EOF
{
  "_generated": "by setup.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Edit by hand to tweak; re-run setup.sh to regenerate.",
  "mcpServers": {${SERVERS}
  }
}
EOF
  chmod 600 "$MCP_CONFIG"
  ok "wrote $MCP_CONFIG (chmod 600)"
  warn "  this file contains secrets — DO NOT commit it. Already covered by .gitignore."
fi

# ============================================================
# Step 5 — memory.md seed
# ============================================================
if [[ $MCP_ONLY -eq 0 ]]; then
heading "5. memory.md seed"

MEMORY_FILE="$MEMORY_DIR/memory.md"
if [[ -f "$MEMORY_FILE" ]]; then
  skip "$MEMORY_FILE already exists; not overwriting"
else
  cat > "$MEMORY_FILE" <<EOF
# Calendar Plan Automation Memory

Append-only durable observations from \`calendar-plan auto\` runs. Do not replace prior history unless the user explicitly requests compaction.

EOF
  chmod 600 "$MEMORY_FILE"
  ok "seeded $MEMORY_FILE"
fi

fi  # end Step 5 (MCP_ONLY guard)

# ============================================================
# Step 6 — doctor.sh (always runs — useful for both flows)
# ============================================================
heading "6. Health check"

if [[ -x "$SKILL_DIR/doctor.sh" ]]; then
  bash "$SKILL_DIR/doctor.sh" || warn "doctor.sh reported issues; review above"
else
  skip "doctor.sh not executable; run: chmod +x $SKILL_DIR/doctor.sh"
fi

echo
ok "setup done."
say "Test with:  bash $SKILL_DIR/calendar-plan.sh --dry-run"
say "Then:       bash $SKILL_DIR/calendar-plan.sh --mode draft"
say "Schedule:   see $SKILL_DIR/launchd/com.user.calendar-plan.plist.example"
