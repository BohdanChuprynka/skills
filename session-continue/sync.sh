#!/usr/bin/env bash
# Copy repo edits into the Codex install. Restart Codex after running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="session-continue"
SRC="$SCRIPT_DIR/skills/$SKILL_NAME"
DST="$HOME/.codex/skills/$SKILL_NAME"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,8p' "$0" | sed 's|^# *||'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SRC" ]]; then
  echo "FATAL: source skill missing: $SRC" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would replace $DST from $SRC"
  exit 0
fi

rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -R "$SRC" "$DST"
echo "copied $SRC -> $DST"
echo "Restart Codex to pick up skill changes."
