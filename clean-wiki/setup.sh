#!/usr/bin/env bash
# clean-wiki setup script. Idempotent: safe to re-run after pulling updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="clean-wiki"
SKILL_DIR="$SCRIPT_DIR/skills/$SKILL_NAME"
CONFIG_FILE="$SKILL_DIR/config/vault-paths.toml"
PYTHON_BIN="${PYTHON:-python3}"

cyan() { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }

require_python() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    red "  x $PYTHON_BIN not found"
    exit 1
  fi

  if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    red "  x Python 3.11+ required (need stdlib tomllib)"
    exit 1
  fi

  green "  ok $("$PYTHON_BIN" --version)"
}

warn_if_placeholder_config() {
  local config_file="$1"
  if config_has_placeholders "$config_file"; then
    yellow "  warn $config_file still contains placeholder vault paths"
  fi
}

config_has_placeholders() {
  local config_file="$1"
  grep -q "/ABSOLUTE/PATH/" "$config_file" 2>/dev/null
}

ensure_config() {
  local target_skill_dir="$1"
  local source_config="${2:-}"
  local target_config="$target_skill_dir/config/vault-paths.toml"
  local target_example="$target_skill_dir/config/vault-paths.example.toml"

  mkdir -p "$target_skill_dir/config"

  if [[ -f "$target_config" ]]; then
    green "  ok config preserved -> $target_config"
    warn_if_placeholder_config "$target_config"
    return
  fi

  if [[ -n "$source_config" && -f "$source_config" ]]; then
    cp "$source_config" "$target_config"
    green "  ok config copied -> $target_config"
  else
    cp "$target_example" "$target_config"
    green "  ok config created -> $target_config"
  fi

  warn_if_placeholder_config "$target_config"
}

install_runtime() {
  local target_skill_dir="$1"
  local venv_dir="$target_skill_dir/.venv"
  local requirements_file="$target_skill_dir/requirements.txt"

  # Defaults to python3 -m venv unless PYTHON points at another interpreter.
  if [[ "${CLEAN_WIKI_SETUP_SKIP_DEPS:-0}" == "1" ]]; then
    yellow "  warn skipped dependency install for $target_skill_dir"
    return
  fi

  "$PYTHON_BIN" -m venv "$venv_dir"
  "$venv_dir/bin/python" -m pip install --upgrade pip
  "$venv_dir/bin/python" -m pip install -r "$requirements_file"
  green "  ok runtime -> $venv_dir"
}

copy_sanitized_skill_dir() {
  local src="$1"
  local dst="$2"

  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"

  "$PYTHON_BIN" - "$src" "$dst" <<'PY'
from pathlib import Path
import shutil
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

ignored_names = {
    ".venv",
    ".pytest_cache",
    "__pycache__",
    "data",
    "logs",
    "reports",
    ".usage-log.jsonl",
    ".apply-log.jsonl",
}


def ignore(directory, names):
    current = Path(directory)
    ignored = {
        name
        for name in names
        if name in ignored_names or name.endswith(".pyc") or name.endswith(".log")
    }
    if current == src / "config":
        ignored.add("vault-paths.toml")
    return ignored


shutil.copytree(src, dst, ignore=ignore)
PY
}

cyan "==> clean-wiki setup"
cyan "    repo: $SCRIPT_DIR"
echo

cyan "==> Checking prerequisites"
require_python
echo

cyan "==> Preparing repo-local runtime"
ensure_config "$SKILL_DIR"
install_runtime "$SKILL_DIR"
echo

cyan "==> Wiring Claude Code"
CLAUDE_SKILLS="$HOME/.claude/skills"
if command -v claude >/dev/null 2>&1 || [[ -d "$HOME/.claude" ]]; then
  mkdir -p "$CLAUDE_SKILLS"
  CLAUDE_SKILL_PATH="$CLAUDE_SKILLS/$SKILL_NAME"
  if [[ -L "$CLAUDE_SKILL_PATH" ]]; then
    rm "$CLAUDE_SKILL_PATH"
  elif [[ -e "$CLAUDE_SKILL_PATH" ]]; then
    CLAUDE_BACKUP="$CLAUDE_SKILL_PATH.backup-$(date +%Y%m%d%H%M%S)-$$"
    mv "$CLAUDE_SKILL_PATH" "$CLAUDE_BACKUP"
    yellow "  warn existing Claude skill moved -> $CLAUDE_BACKUP"
  fi
  ln -s "$SKILL_DIR" "$CLAUDE_SKILLS/$SKILL_NAME"
  green "  ok skill -> $CLAUDE_SKILLS/$SKILL_NAME"
else
  yellow "  warn ~/.claude not found and claude not on PATH; skipped Claude Code install"
fi
echo

cyan "==> Wiring Codex"
CODEX_SKILLS="$HOME/.codex/skills"
mkdir -p "$CODEX_SKILLS"
CODEX_SKILL_DIR="$CODEX_SKILLS/$SKILL_NAME"
PRESERVED_CODEX_STATE="$(mktemp -d)"
if [[ -f "$CODEX_SKILL_DIR/config/vault-paths.toml" ]]; then
  mkdir -p "$PRESERVED_CODEX_STATE/config"
  cp "$CODEX_SKILL_DIR/config/vault-paths.toml" "$PRESERVED_CODEX_STATE/config/vault-paths.toml"
fi
for state_dir in data logs reports; do
  if [[ -e "$CODEX_SKILL_DIR/$state_dir" ]]; then
    cp -R "$CODEX_SKILL_DIR/$state_dir" "$PRESERVED_CODEX_STATE/$state_dir"
  fi
done

copy_sanitized_skill_dir "$SKILL_DIR" "$CODEX_SKILL_DIR"
if [[ -f "$PRESERVED_CODEX_STATE/config/vault-paths.toml" ]]; then
  if config_has_placeholders "$PRESERVED_CODEX_STATE/config/vault-paths.toml" \
    && [[ -f "$CONFIG_FILE" ]] \
    && ! config_has_placeholders "$CONFIG_FILE"; then
    ensure_config "$CODEX_SKILL_DIR" "$CONFIG_FILE"
  else
    ensure_config "$CODEX_SKILL_DIR" "$PRESERVED_CODEX_STATE/config/vault-paths.toml"
  fi
else
  ensure_config "$CODEX_SKILL_DIR" "$CONFIG_FILE"
fi
for state_dir in data logs reports; do
  if [[ -e "$PRESERVED_CODEX_STATE/$state_dir" ]]; then
    rm -rf "$CODEX_SKILL_DIR/$state_dir"
    mv "$PRESERVED_CODEX_STATE/$state_dir" "$CODEX_SKILL_DIR/$state_dir"
  fi
done
rm -rf "$PRESERVED_CODEX_STATE"
install_runtime "$CODEX_SKILL_DIR"
green "  ok skill -> $CODEX_SKILL_DIR"
echo

green "==> Done."
echo
echo "Claude Code: /clean-wiki"
echo "Codex:       restart Codex, then use:"
echo "             Use \$clean-wiki to audit my Obsidian vaults."
echo
echo "Edit config before first use if placeholders remain:"
echo "  Repo:  $CONFIG_FILE"
echo "  Codex: $CODEX_SKILL_DIR/config/vault-paths.toml"
