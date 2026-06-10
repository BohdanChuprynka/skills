#!/usr/bin/env bash
# session-continue setup script. Idempotent: safe to re-run after pulling updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="session-continue"
SKILL_DIR="$SCRIPT_DIR/skills/$SKILL_NAME"

cyan() { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }

copy_skill_dir() {
  local dst="$1"
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -R "$SKILL_DIR" "$dst"
}

cyan "==> session-continue setup"
cyan "    repo: $SCRIPT_DIR"
echo

cyan "==> Checking prerequisites"
if ! command -v node >/dev/null 2>&1; then
  red "  x node not found"
  exit 1
fi
green "  ok node ($(node --version))"

if command -v continues >/dev/null 2>&1; then
  green "  ok continues ($(continues --version 2>&1 | head -1))"
elif command -v cont >/dev/null 2>&1; then
  green "  ok cont ($(cont --version 2>&1 | head -1))"
elif command -v npm >/dev/null 2>&1; then
  yellow "  warn continues not installed globally; helper will fall back to npm exec"
else
  red "  x neither continues/cont nor npm found"
  exit 1
fi
echo

cyan "==> Wiring Claude Code"
CLAUDE_SKILLS="$HOME/.claude/skills"
CLAUDE_CMDS="$HOME/.claude/commands"
if command -v claude >/dev/null 2>&1 || [[ -d "$HOME/.claude" ]]; then
  mkdir -p "$CLAUDE_SKILLS" "$CLAUDE_CMDS"
  rm -rf "$CLAUDE_SKILLS/$SKILL_NAME"
  ln -s "$SKILL_DIR" "$CLAUDE_SKILLS/$SKILL_NAME"
  cp "$SCRIPT_DIR/commands/$SKILL_NAME.md" "$CLAUDE_CMDS/$SKILL_NAME.md"
  green "  ok skill   -> $CLAUDE_SKILLS/$SKILL_NAME"
  green "  ok command -> $CLAUDE_CMDS/$SKILL_NAME.md"
else
  yellow "  warn ~/.claude not found and claude not on PATH; skipped Claude install"
fi
echo

cyan "==> Wiring Codex"
CODEX_SKILLS="$HOME/.codex/skills"
if command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]]; then
  mkdir -p "$CODEX_SKILLS"
  copy_skill_dir "$CODEX_SKILLS/$SKILL_NAME"
  green "  ok skill -> $CODEX_SKILLS/$SKILL_NAME"
else
  yellow "  warn ~/.codex not found and codex not on PATH; skipped Codex install"
fi
echo

green "==> Done."
echo
echo "Claude Code: /session-continue from codex <session-id> -- continue the task"
echo "Codex:       restart Codex, then use:"
echo "             Use \$session-continue from claude <session-id> -- continue the task"
