#!/usr/bin/env bash
# Compatibility wrapper. The real installer lives at the repo root and handles
# both Claude Code and Codex installs from one source.
set -euo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
if [[ ! -x "$REPO_ROOT/setup.sh" ]]; then
  echo "FATAL: $REPO_ROOT/setup.sh not found or not executable." >&2
  exit 1
fi
exec bash "$REPO_ROOT/setup.sh" "$@"
