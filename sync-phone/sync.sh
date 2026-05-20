#!/usr/bin/env bash
#
# sync.sh — push repo edits into the Codex install of sync-phone.
#
# The Claude install is a symlink to this repo and picks up edits automatically.
# Codex does NOT follow symlinks for skill discovery, so we copy the Codex
# artifacts (SKILL.md + agents/openai.yaml) into ~/.codex/skills/sync-phone/.
#
# After running, RESTART Codex — it scans skills at startup only.
#
# Usage:
#   bash sync.sh              # full sync
#   bash sync.sh --dry-run    # show what would change, write nothing
#   bash sync.sh --help

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_SKILL_DIR="$HOME/.codex/skills/sync-phone"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,15p' "$0" | sed 's|^# *||'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$CODEX_SKILL_DIR" ]]; then
  echo "FATAL: $CODEX_SKILL_DIR not found — run setup.sh first." >&2
  exit 1
fi

MISSING=0
copy_one() {  # $1 src, $2 dst, $3 label
  local src="$1" dst="$2" label="$3"
  if [[ ! -f "$src" ]]; then
    echo "  FATAL: $label source missing at $src" >&2
    MISSING=1
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      echo "  unchanged: $label"
    elif [[ -f "$dst" ]]; then
      echo "  would update: $label  ($(wc -c < "$dst") → $(wc -c < "$src") bytes)"
    else
      echo "  would create: $label  ($(wc -c < "$src") bytes)"
    fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "  copied:   $label"
  fi
}

echo "== Codex skill files =="
copy_one "$REPO_DIR/codex/SKILL.md"                   "$CODEX_SKILL_DIR/SKILL.md"               "SKILL.md"             || true
copy_one "$REPO_DIR/codex/agents/openai.example.yaml" "$CODEX_SKILL_DIR/agents/openai.yaml"     "agents/openai.yaml"   || true

if [[ "$MISSING" == "1" ]]; then
  echo
  echo "✗ One or more source files were missing — Codex install may be stale." >&2
  echo "  Re-clone or pull the repo, then re-run sync.sh." >&2
  exit 1
fi

if [[ "$DRY_RUN" == "0" ]]; then
  echo
  echo "✓ Codex install in sync with repo."
  echo "  RESTART Codex to pick up skill changes (Codex scans skills at startup only)."
fi
