#!/usr/bin/env bash
# setup.sh — interactive setup wizard for dream-skill.
#
# Walks the user through:
#   1. Prerequisite checks (python3.11+, claude CLI)
#   2. Vault root selection
#   3. Vault-categories config (config/vault-paths.toml)
#   4. Optional MCP integrations (config/mcp-config.json)
#   5. doctor.sh health check
#
# The wizard is linear, well-prompted, and every step can be skipped.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SKILL_DIR/config"

# Colors (disable if not a tty)
if [[ -t 1 ]]; then
  C_DIM="$(printf '\033[2m')"
  C_BOLD="$(printf '\033[1m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
  C_BLUE="$(printf '\033[34m')"
  C_RESET="$(printf '\033[0m')"
else
  C_DIM=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi

say()    { printf "%s\n" "$*"; }
prompt() { printf "%s" "$*"; }
heading() {
  printf "\n${C_BOLD}${C_BLUE}== %s ==${C_RESET}\n" "$*"
}
ok()     { printf "${C_GREEN}OK${C_RESET}  %s\n" "$*"; }
warn()   { printf "${C_YELLOW}WARN${C_RESET} %s\n" "$*"; }
err()    { printf "${C_RED}FAIL${C_RESET} %s\n" "$*"; }
skip()   { printf "${C_DIM}skip${C_RESET}  %s\n" "$*"; }

# Read with default value
read_default() {
  local prompt_text="$1" default_val="$2" __out
  prompt "${prompt_text} ${C_DIM}[${default_val}]${C_RESET}: "
  read -r __out
  if [[ -z "$__out" ]]; then __out="$default_val"; fi
  REPLY="$__out"
}

# yes/no with default
read_yn() {
  local prompt_text="$1" default_yn="$2" __out
  local hint
  if [[ "$default_yn" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  prompt "${prompt_text} ${hint}: "
  read -r __out
  __out="${__out:-$default_yn}"
  case "$__out" in
    y|Y|yes|YES) REPLY="y" ;;
    *)           REPLY="n" ;;
  esac
}

heading "dream-skill setup"
say "This wizard configures the skill on this machine."
say "Every step is skippable; nothing is sent over the network until you finish."

# ============================================================
# Step 1 — prerequisites
# ============================================================

heading "1. Prerequisites"

# python 3.11+
if command -v python3 >/dev/null 2>&1; then
  PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  PY_MAJOR="${PY_VER%%.*}"
  PY_MINOR="${PY_VER##*.}"
  if [[ "$PY_MAJOR" -ge 3 ]] && [[ "$PY_MINOR" -ge 11 ]]; then
    ok "python3 $PY_VER"
  else
    err "python3 $PY_VER (need 3.11+ for tomllib)"
    say "  install via: brew install python@3.11   (macOS)"
    say "               apt install python3.11      (Debian/Ubuntu)"
    exit 1
  fi
else
  err "python3 not found on PATH"
  say "  install python 3.11+ before continuing"
  exit 1
fi

# claude CLI
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI on PATH ($(command -v claude))"
else
  err "'claude' CLI not on PATH"
  say "  install: https://docs.claude.com/claude-code"
  read_yn "  continue anyway?" "n"
  if [[ "$REPLY" != "y" ]]; then exit 1; fi
fi

# ============================================================
# Step 2 — vault root
# ============================================================

heading "2. Vault root"
say "Where lives your Obsidian vault? (the directory containing your sub-vaults)"
DEFAULT_VAULT="$HOME/Documents/Obsidian"
read_default "  vault root" "$DEFAULT_VAULT"
VAULT_ROOT="$REPLY"
# Expand ~ if user typed it
VAULT_ROOT="${VAULT_ROOT/#\~/$HOME}"

if [[ ! -d "$VAULT_ROOT" ]]; then
  warn "directory does not exist: $VAULT_ROOT"
  read_yn "  create it?" "n"
  if [[ "$REPLY" == "y" ]]; then
    mkdir -p "$VAULT_ROOT"
    ok "created $VAULT_ROOT"
  else
    say "  continuing without creating; doctor.sh will flag this later"
  fi
else
  ok "exists: $VAULT_ROOT"
fi

# ============================================================
# Step 3 — vault categories
# ============================================================

heading "3. Vault categories"
say "Pick the sub-vaults dream-skill should scan. (each = a top-level subfolder of your vault root)"
say "Common categories: ${C_DIM}persona, projects, fitness, learning, notes${C_RESET}"

CATEGORIES=()
read_yn "  configure vault categories now?" "y"
if [[ "$REPLY" == "y" ]]; then
  # Auto-detect existing subdirs
  AUTO_DETECTED=()
  if [[ -d "$VAULT_ROOT" ]]; then
    while IFS= read -r d; do
      base="$(basename "$d")"
      # Skip hidden dirs and the output dir
      if [[ "$base" == .* ]] || [[ "$base" == "dream-reports" ]]; then continue; fi
      AUTO_DETECTED+=("$base")
    done < <(find "$VAULT_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi

  if [[ ${#AUTO_DETECTED[@]} -gt 0 ]]; then
    say "  auto-detected subdirs of vault root:"
    for c in "${AUTO_DETECTED[@]}"; do say "    - $c"; done
    read_yn "  use these as your vault list?" "y"
    if [[ "$REPLY" == "y" ]]; then
      CATEGORIES=("${AUTO_DETECTED[@]}")
    fi
  fi

  if [[ ${#CATEGORIES[@]} -eq 0 ]]; then
    say "  enter vault names one per line, blank line to finish:"
    while true; do
      prompt "    > "
      read -r name
      if [[ -z "$name" ]]; then break; fi
      CATEGORIES+=("$name")
    done
  fi
else
  skip "  vault-paths.toml will not be written; load_vault_state.py will fall back to walking all .md files"
fi

if [[ ${#CATEGORIES[@]} -gt 0 ]]; then
  TOML_PATH="$CONFIG_DIR/vault-paths.toml"
  mkdir -p "$CONFIG_DIR"
  {
    echo "# Generated by setup.sh on $(date -u +%F)"
    echo "# Sub-vaults that dream-skill scans during reconciliation."
    echo ""
    echo "vault_root = \"$VAULT_ROOT\""
    echo ""
    echo "# Order matters: first = highest priority in the LLM context."
    echo "vaults = ["
    for c in "${CATEGORIES[@]}"; do
      echo "  \"$c\","
    done
    echo "]"
    echo ""
    echo "# Pages with frontmatter 'updated:' older than this are flagged as stale."
    echo "stale_days = 60"
  } > "$TOML_PATH"
  ok "wrote $TOML_PATH"
fi

# ============================================================
# Step 4 — MCP integrations
# ============================================================

heading "4. MCP integrations (optional)"
say "dream-skill can probe external sources to corroborate signals."
say "Each integration runs as a local stdio MCP server, isolated to the dream-cycle subprocess."
say ""
say "Choose any combination — or none. Skip any you don't want."

MCP_SERVERS_JSON=""

ask_mcp() {
  local label="$1" prompt_text="${2:-}"
  read_yn "  add $label MCP?" "n"
  [[ "$REPLY" == "y" ]]
}

# Notion
if ask_mcp "Notion"; then
  say "    docs: https://developers.notion.com/docs/create-a-notion-integration"
  prompt "    Notion integration token (starts with 'secret_' or 'ntn_'): "
  read -rs NOTION_TOKEN
  echo
  if [[ -n "$NOTION_TOKEN" ]]; then
    MCP_SERVERS_JSON="${MCP_SERVERS_JSON}
    \"notion\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"@notionhq/notion-mcp-server\"],
      \"env\": { \"NOTION_TOKEN\": \"${NOTION_TOKEN}\" }
    },"
    ok "    notion configured"
  else
    warn "    no token entered; skipping notion"
  fi
fi

# Google Calendar
if ask_mcp "Google Calendar"; then
  say "    most community Calendar MCPs need a one-time OAuth flow."
  say "    search npm: https://www.npmjs.com/search?q=google-calendar%20mcp"
  prompt "    npm package name (e.g. 'community-gcal-mcp'): "
  read -r GCAL_PKG
  prompt "    path to OAuth credentials.json (leave blank to skip): "
  read -r GCAL_CREDS
  GCAL_CREDS="${GCAL_CREDS/#\~/$HOME}"
  if [[ -n "$GCAL_PKG" ]]; then
    MCP_SERVERS_JSON="${MCP_SERVERS_JSON}
    \"google-calendar\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"${GCAL_PKG}\"],
      \"env\": { \"CREDENTIALS_PATH\": \"${GCAL_CREDS}\" }
    },"
    ok "    google-calendar configured"
  fi
fi

# Gmail
if ask_mcp "Gmail"; then
  say "    search npm: https://www.npmjs.com/search?q=gmail%20mcp"
  prompt "    npm package name: "
  read -r GMAIL_PKG
  prompt "    path to credentials.json (leave blank to skip): "
  read -r GMAIL_CREDS
  GMAIL_CREDS="${GMAIL_CREDS/#\~/$HOME}"
  if [[ -n "$GMAIL_PKG" ]]; then
    MCP_SERVERS_JSON="${MCP_SERVERS_JSON}
    \"gmail\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"${GMAIL_PKG}\"],
      \"env\": { \"CREDENTIALS_PATH\": \"${GMAIL_CREDS}\" }
    },"
    ok "    gmail configured"
  fi
fi

# Filesystem (vault-readonly)
if ask_mcp "Filesystem (read-only vault access)"; then
  MCP_SERVERS_JSON="${MCP_SERVERS_JSON}
    \"filesystem-vault\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"${VAULT_ROOT}\"]
    },"
  ok "    filesystem MCP configured (scoped to ${VAULT_ROOT})"
fi

if [[ -n "$MCP_SERVERS_JSON" ]]; then
  MCP_PATH="$CONFIG_DIR/mcp-config.json"
  # Strip trailing comma from last server
  MCP_SERVERS_JSON="${MCP_SERVERS_JSON%,}"
  cat > "$MCP_PATH" <<EOF
{
  "_README": "Generated by setup.sh on $(date -u +%F). Edit by hand to tweak. Re-run setup.sh to regenerate.",
  "mcpServers": {${MCP_SERVERS_JSON}
  }
}
EOF
  ok "wrote $MCP_PATH"
  chmod 600 "$MCP_PATH" 2>/dev/null || true
  warn "  this file contains secrets — permissions set to 600. Do NOT commit it."
else
  skip "  no MCP integrations configured; dream.sh will run Tier 0 (sessions + vault only)"
fi

# ============================================================
# Step 5 — health check
# ============================================================

heading "5. Health check"
if [[ -x "$SKILL_DIR/doctor.sh" ]]; then
  DREAM_VAULT_ROOT="$VAULT_ROOT" "$SKILL_DIR/doctor.sh" || true
else
  warn "doctor.sh not found or not executable; skipping"
fi

# ============================================================
# Done
# ============================================================

heading "Setup complete"
say "  vault root:       $VAULT_ROOT"
if [[ ${#CATEGORIES[@]} -gt 0 ]]; then
  say "  vault categories: ${CATEGORIES[*]}"
fi
if [[ -n "$MCP_SERVERS_JSON" ]]; then
  say "  MCP config:       $CONFIG_DIR/mcp-config.json"
else
  say "  MCP config:       (none — Tier 0 mode)"
fi
say ""
say "Next:"
say "  ${C_BOLD}DREAM_VAULT_ROOT=\"$VAULT_ROOT\" ./dream.sh --dry-run${C_RESET}"
say ""
say "or set DREAM_VAULT_ROOT in your shell rc and just run ./dream.sh"
