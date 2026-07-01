#!/usr/bin/env bash
# clean-wiki — review server launcher.
#
# The active agent scans + applies. This script only starts the swipe-review web UI.
# Run after the agent writes data/cleanup-queue.json.
#
# Usage:
#   bash clean-wiki.sh        # launch review UI (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="${PYTHON:-python3}"
fi

cd "$SCRIPT_DIR"

if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  echo "error: Python 3.11+ required (need stdlib tomllib)" >&2
  exit 1
fi

if [ ! -f "config/vault-paths.toml" ]; then
  echo "error: config/vault-paths.toml not found" >&2
  echo "hint:  cp config/vault-paths.example.toml config/vault-paths.toml" >&2
  echo "       (then edit it with your vault paths)" >&2
  exit 1
fi

if ! "$PYTHON_BIN" -c 'import flask' 2>/dev/null; then
  echo "error: flask not installed — pip install -r requirements.txt" >&2
  exit 1
fi

if [ ! -f "data/cleanup-queue.json" ]; then
  echo "warn: no data/cleanup-queue.json found — UI will show an empty state." >&2
  echo "      Run /clean-wiki in Claude Code or use \$clean-wiki in Codex first." >&2
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/scripts/serve.py" "$@"
