#!/usr/bin/env bash
# Symlink blueprint into the Claude Code and Codex skill folders, then build the starter example once.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/blueprint"
[ -d "$src" ] || { echo "missing $src" >&2; exit 1; }

for dest in "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" "${CODEX_HOME:-$HOME/.codex}/skills"; do
  mkdir -p "$dest"
  target="$dest/blueprint"
  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ]; then
    echo "refusing to replace $target: exists and is not a symlink" >&2
    exit 1
  fi
  ln -s "$src" "$target"
  echo "linked $target -> $src"
done

tmp="$(mktemp -d)"
cp -R "$src/examples/minimal/." "$tmp/"
python3 "$src/scripts/build.py" "$tmp"
echo "Self-test passed. For the browser check: python3 $src/scripts/check.py $tmp/blueprint-architecture.html"
