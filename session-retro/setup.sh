#!/usr/bin/env bash
# Symlink session-retro into ~/.claude/skills.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/session-retro"
dest="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

[ -d "$src" ] || { echo "missing $src" >&2; exit 1; }
mkdir -p "$dest"

target="$dest/session-retro"
if [ -L "$target" ]; then
  rm "$target"
elif [ -e "$target" ]; then
  echo "refusing to replace $target: exists and is not a symlink" >&2
  exit 1
fi

ln -s "$src" "$target"
echo "linked $target -> $src"
python3 "$src/scan.py" --selftest
