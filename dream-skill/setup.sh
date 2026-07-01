#!/usr/bin/env bash
# setup.sh — idempotent local install for dream-skill (Claude Code + Codex).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$REPO_DIR/skills/dream-skill"
CONFIG_EXAMPLE="$REPO_DIR/config.example.toml"
STATE_DIR="$HOME/.claude/dream-skill"
CLAUDE_INSTALL="$HOME/.claude/skills/dream-skill"
CODEX_INSTALL="$HOME/.codex/skills/dream-skill"

if [[ -t 1 ]]; then
  B=$'\e[1m'; D=$'\e[2m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; BL=$'\e[34m'; X=$'\e[0m'
else
  B=; D=; R=; G=; Y=; BL=; X=
fi
heading() { echo; echo "${B}${BL}== $1 ==${X}"; }
ok()      { echo "  ${G}OK${X}  $*"; }
warn()    { echo "  ${Y}WARN${X}  $*"; }
fail()    { echo "  ${R}FAIL${X}  $*"; exit 1; }
skip()    { echo "  ${D}skip${X}  $*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

copy_codex_skill() {
  rm -rf "$CODEX_INSTALL"
  mkdir -p "$CODEX_INSTALL/agents"

  cp "$SKILL_SRC/SKILL.md" "$CODEX_INSTALL/SKILL.md"
  cp "$REPO_DIR/ROUTING.md" "$CODEX_INSTALL/ROUTING.md"
  cp "$REPO_DIR/requirements.txt" "$CODEX_INSTALL/requirements.txt"
  cp "$REPO_DIR/codex/agents/openai.example.yaml" "$CODEX_INSTALL/agents/openai.yaml"
  cp -R "$REPO_DIR/scripts" "$CODEX_INSTALL/scripts"
  cp -R "$REPO_DIR/web" "$CODEX_INSTALL/web"

  find "$CODEX_INSTALL" -type d \( -name '__pycache__' -o -name '.pytest_cache' \) -prune -exec rm -rf {} +
  find "$CODEX_INSTALL" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
  find "$CODEX_INSTALL/scripts" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
}

heading "0. Prereqs"
have_cmd python3 || fail "python3 is required"
ok "python3: $(python3 --version 2>&1 | head -1)"
have_cmd jq || fail "jq is required (brew install jq / apt install jq)"
ok "jq: $(jq --version 2>&1 | head -1)"

have_claude=0
have_codex=0
have_cmd claude && have_claude=1
have_cmd codex && have_codex=1
if [[ $have_claude -eq 1 ]]; then ok "claude: $(claude --version 2>&1 | head -1)"; else warn "claude not on PATH"; fi
if [[ $have_codex -eq 1 ]]; then ok "codex: $(codex --version 2>&1 | head -1)"; else warn "codex not on PATH"; fi

heading "1. Runtime state"
mkdir -p "$STATE_DIR/queue/sidecars" "$STATE_DIR/log" "$STATE_DIR/undo" "$STATE_DIR/tmp"
ok "ensured $STATE_DIR/{queue/sidecars,log,undo,tmp}"
if [[ -f "$STATE_DIR/config.toml" ]]; then
  ok "kept existing $STATE_DIR/config.toml"
else
  [[ -f "$CONFIG_EXAMPLE" ]] || fail "missing config template: $CONFIG_EXAMPLE"
  cp "$CONFIG_EXAMPLE" "$STATE_DIR/config.toml"
  chmod 600 "$STATE_DIR/config.toml"
  warn "seeded $STATE_DIR/config.toml from config.example.toml; edit vault paths before the first real run"
fi

heading "2. Claude Code skill"
mkdir -p "$(dirname "$CLAUDE_INSTALL")"
if [[ -L "$CLAUDE_INSTALL" ]]; then
  target="$(readlink "$CLAUDE_INSTALL")"
  if [[ "$target" == "$SKILL_SRC" ]]; then
    ok "already symlinked: $CLAUDE_INSTALL -> $target"
  else
    rm -f "$CLAUDE_INSTALL"
    ln -s "$SKILL_SRC" "$CLAUDE_INSTALL"
    ok "updated symlink: $CLAUDE_INSTALL -> $SKILL_SRC"
  fi
elif [[ -e "$CLAUDE_INSTALL" ]]; then
  warn "$CLAUDE_INSTALL exists and is not a symlink; leaving it untouched"
else
  ln -s "$SKILL_SRC" "$CLAUDE_INSTALL"
  ok "symlinked $CLAUDE_INSTALL -> $SKILL_SRC"
fi

heading "3. Codex skill"
mkdir -p "$(dirname "$CODEX_INSTALL")"
copy_codex_skill
ok "copied self-contained Codex skill to $CODEX_INSTALL"
if [[ $have_codex -ne 1 ]]; then
  warn "codex is not on PATH yet; the local skill is installed and will be available after Codex is installed/restarted"
fi

echo
ok "${B}setup complete.${X}"
echo
echo "  Config: $STATE_DIR/config.toml"
echo
echo "  Claude Code:"
echo "    /dream-skill --dry-run"
echo "    /dream-skill"
echo
echo "  Codex:"
echo "    Restart Codex, then run:"
echo "    Use \$dream-skill --dry-run"
echo "    Use \$dream-skill"
echo
echo "  Source options:"
echo "    --source claude   scan Claude Code transcripts only"
echo "    --source codex    scan Codex transcripts only"
echo "    --source all      scan both sources"
