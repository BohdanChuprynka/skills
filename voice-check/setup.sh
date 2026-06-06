#!/usr/bin/env bash
# voice-check setup script.
# Idempotent: safe to re-run after pulling updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="voice-check"

cyan() { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }

cyan "==> voice-check setup"
cyan "    repo: $SCRIPT_DIR"
echo

# --- 1. Prerequisites (stdlib-only tool — just needs Python 3.10+)
cyan "==> Checking prerequisites"
if ! command -v python3 >/dev/null 2>&1; then
  red "  ✗ python3 not found"
  exit 1
fi
green "  ✓ python ($(python3 --version))"
echo

# --- 2. Install the voice-check CLI
cyan "==> Installing the voice-check CLI"
if command -v uv >/dev/null 2>&1; then
  uv tool install --force --reinstall "$SCRIPT_DIR"
  green "  ✓ Installed via uv"
elif command -v pipx >/dev/null 2>&1; then
  pipx install --force "$SCRIPT_DIR"
  green "  ✓ Installed via pipx"
else
  python3 -m pip install --user --upgrade "$SCRIPT_DIR"
  green "  ✓ Installed via pip --user"
  yellow "  → Make sure your user scripts dir (e.g. ~/.local/bin) is on PATH"
fi
echo

# --- 3. Canonical profile location
cyan "==> Profile location"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/voice-check/profile"
mkdir -p "$CONFIG_DIR"
green "  ✓ $CONFIG_DIR"
echo

# --- 4. Claude Code: symlink skill + slash command
cyan "==> Wiring Claude Code skill + command"
CLAUDE_SKILLS="$HOME/.claude/skills"
CLAUDE_CMDS="$HOME/.claude/commands"
mkdir -p "$CLAUDE_SKILLS" "$CLAUDE_CMDS"

relink() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    rm -rf "$dst"
  fi
  ln -s "$src" "$dst"
}

relink "$SCRIPT_DIR/skills/$SKILL_NAME" "$CLAUDE_SKILLS/$SKILL_NAME"
green "  ✓ skill   → $CLAUDE_SKILLS/$SKILL_NAME"
relink "$SCRIPT_DIR/commands/$SKILL_NAME.md" "$CLAUDE_CMDS/$SKILL_NAME.md"
green "  ✓ command → $CLAUDE_CMDS/$SKILL_NAME.md"
echo

# --- 5. Codex: copy skill (Codex uses real directories, not symlinks)
cyan "==> Wiring Codex skill"
CODEX_SKILLS="$HOME/.codex/skills"
if [ -d "$HOME/.codex" ]; then
  mkdir -p "$CODEX_SKILLS/$SKILL_NAME"
  cp "$SCRIPT_DIR/skills/$SKILL_NAME/SKILL.md" "$CODEX_SKILLS/$SKILL_NAME/SKILL.md"
  green "  ✓ skill   → $CODEX_SKILLS/$SKILL_NAME/ (copy)"
else
  yellow "  → ~/.codex not found; skipping Codex install"
fi
echo

green "==> Done."
echo
echo "Next steps:"
echo "  1. Build your profile:"
echo "       voice-check profile --input <dir-of-your-writing> --out $CONFIG_DIR"
echo "  2. Audit a draft:"
echo "       voice-check check --profile $CONFIG_DIR --draft path/to/draft.md"
echo "  3. In Claude Code or Codex: /voice-check"
