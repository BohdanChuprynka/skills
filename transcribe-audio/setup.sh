#!/usr/bin/env bash
# transcribe-audio setup script.
# Idempotent: safe to re-run after pulling updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="transcribe-audio"

cyan() { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }

cyan "==> transcribe-audio setup"
cyan "    repo: $SCRIPT_DIR"
echo

# --- 1. Check prerequisites
cyan "==> Checking prerequisites"

if ! command -v ffmpeg >/dev/null 2>&1; then
  red "  ✗ ffmpeg not found"
  echo "    Install: brew install ffmpeg  (macOS)"
  echo "             sudo apt install ffmpeg  (Ubuntu)"
  exit 1
fi
green "  ✓ ffmpeg"

if ! command -v uv >/dev/null 2>&1; then
  red "  ✗ uv not found"
  echo "    Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi
green "  ✓ uv ($(uv --version | head -1))"

if ! command -v python3 >/dev/null 2>&1; then
  red "  ✗ python3 not found"
  exit 1
fi
green "  ✓ python ($(python3 --version))"
echo

# --- 2. .env file
cyan "==> .env setup"
if [ ! -f "$SCRIPT_DIR/.env.example" ]; then
  red "  ✗ .env.example missing — repo is in a bad state"
  exit 1
fi

# Canonical location for the installed CLI is ~/.config/transcribe-audio/.env
# so the binary can find credentials regardless of cwd.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/transcribe-audio"
mkdir -p "$CONFIG_DIR"
CANONICAL_ENV="$CONFIG_DIR/.env"

if [ ! -f "$CANONICAL_ENV" ]; then
  cp "$SCRIPT_DIR/.env.example" "$CANONICAL_ENV"
  chmod 600 "$CANONICAL_ENV"
  yellow "  → Created $CANONICAL_ENV from .env.example"
  yellow "  → Edit it and add your OPENAI_API_KEY before first run"
else
  green "  ✓ $CANONICAL_ENV already exists (not overwriting)"
fi

# Also create a repo-local .env for in-repo development work, if missing.
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  chmod 600 "$SCRIPT_DIR/.env"
  green "  ✓ Also created $SCRIPT_DIR/.env (for in-repo development)"
fi
echo

# --- 3. Install CLI via uv
cyan "==> Installing transcribe-audio CLI"
uv tool install --force --reinstall "$SCRIPT_DIR"
echo
green "  ✓ Installed. Run: transcribe-audio --help"
echo

# --- 4. Symlink skill + slash command into ~/.claude/
cyan "==> Wiring Claude Code skill + command"

CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$CLAUDE_SKILLS_DIR" "$CLAUDE_COMMANDS_DIR"

SKILL_SRC="$SCRIPT_DIR/skills/$SKILL_NAME"
SKILL_LINK="$CLAUDE_SKILLS_DIR/$SKILL_NAME"
if [ -L "$SKILL_LINK" ] || [ -e "$SKILL_LINK" ]; then
  rm -f "$SKILL_LINK"
fi
ln -s "$SKILL_SRC" "$SKILL_LINK"
green "  ✓ Linked $SKILL_LINK → $SKILL_SRC"

CMD_SRC="$SCRIPT_DIR/commands/$SKILL_NAME.md"
CMD_LINK="$CLAUDE_COMMANDS_DIR/$SKILL_NAME.md"
if [ -L "$CMD_LINK" ] || [ -e "$CMD_LINK" ]; then
  rm -f "$CMD_LINK"
fi
ln -s "$CMD_SRC" "$CMD_LINK"
green "  ✓ Linked $CMD_LINK → $CMD_SRC"
echo

# --- 5. Offer to run the init wizard
cyan "==> Optional: run interactive config wizard"
echo "    Sets default language, summary style, Obsidian vault, etc."
echo
read -p "Run [transcribe-audio init] now? [Y/n] " reply
if [[ ! "$reply" =~ ^[Nn]$ ]]; then
  transcribe-audio init
fi

echo
green "==> Done."
echo
echo "Next steps:"
echo "  1. Edit $CANONICAL_ENV and set OPENAI_API_KEY"
echo "  2. transcribe-audio transcribe ~/path/to/audio.mp3"
echo "  3. In Claude Code: /transcribe-audio"
