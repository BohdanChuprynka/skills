#!/usr/bin/env bash
# dream-skill nudge. Runs as SessionStart hook.
# Reads the last-run marker and emits a one-line prompt if a sync may be overdue.
# Never fails, never blocks startup. Outputs nothing on a fresh install.
set -uo pipefail
MARKER="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}/last-run"
[ -f "$MARKER" ] || exit 0
LAST=$(cat "$MARKER" 2>/dev/null || true)
[ -n "$LAST" ] || exit 0
echo "dream-skill: last sync $LAST — /dream-skill to update vault"
exit 0
