#!/usr/bin/env bash
# Compatibility wrapper. Real setup lives at the repo root.
# Delegates to <repo>/setup.sh so users can run setup from either location.
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
if [[ ! -x "$REPO_ROOT/setup.sh" ]]; then
  echo "FATAL: $REPO_ROOT/setup.sh not found." >&2
  exit 1
fi
exec bash "$REPO_ROOT/setup.sh" "$@"
