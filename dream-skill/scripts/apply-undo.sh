#!/usr/bin/env bash
# dream-skill apply-undo.
# Reverses vault-writer.sh actions recorded in an undo log (JSONL).
# Reads entries in reverse order; for each:
#   action=append      → remove "- <content>" from <vault>/<page>
#   action=index_append → remove the inserted line from the index file
# Prints summary of reverted entries.
#
# Usage:
#   apply-undo.sh <undo-log-path>
#   apply-undo.sh --date <YYYY-MM-DD>  (resolves to ~/.claude/dream-skill/undo/<date>.jsonl)

set -euo pipefail

die() { echo "apply-undo: $*" >&2; exit 1; }

UNDO_LOG=""
if [ $# -eq 0 ]; then
  die "usage: apply-undo.sh <undo-log-path>|--date <YYYY-MM-DD>"
elif [ "$1" = "--date" ]; then
  [ -n "${2:-}" ] || die "missing date after --date"
  UNDO_LOG="$HOME/.claude/dream-skill/undo/$2.jsonl"
else
  UNDO_LOG="$1"
fi

[ -f "$UNDO_LOG" ] || die "undo log not found: $UNDO_LOG"
command -v jq >/dev/null 2>&1 || die "jq required"

REVERTED=0
SKIPPED=0

# Reverse order: undo most recent first
tac "$UNDO_LOG" 2>/dev/null > "$UNDO_LOG.rev" || {
  # macOS lacks tac; use awk fallback
  awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}' "$UNDO_LOG" > "$UNDO_LOG.rev"
}

while IFS= read -r line; do
  [ -z "$line" ] && continue

  ACTION=$(echo "$line" | jq -r '.action // empty')

  case "$ACTION" in
    append)
      VAULT=$(echo "$line" | jq -r '.vault')
      PAGE=$(echo "$line" | jq -r '.page')
      CONTENT=$(echo "$line" | jq -r '.content')
      PAGE_PATH="$VAULT/$PAGE"
      if [ -f "$PAGE_PATH" ]; then
        # Remove the line "- <content>" (exact match)
        TARGET="- $CONTENT"
        grep -Fxv -- "$TARGET" "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
        REVERTED=$((REVERTED + 1))
      else
        SKIPPED=$((SKIPPED + 1))
      fi
      ;;
    index_append)
      INDEX_FILE=$(echo "$line" | jq -r '.index_file')
      LINE_TEXT=$(echo "$line" | jq -r '.line')
      if [ -f "$INDEX_FILE" ]; then
        grep -Fxv -- "$LINE_TEXT" "$INDEX_FILE" > "$INDEX_FILE.tmp" && mv "$INDEX_FILE.tmp" "$INDEX_FILE"
        REVERTED=$((REVERTED + 1))
      else
        SKIPPED=$((SKIPPED + 1))
      fi
      ;;
    *)
      SKIPPED=$((SKIPPED + 1))
      ;;
  esac
done < "$UNDO_LOG.rev"

rm -f "$UNDO_LOG.rev"

# Move the processed log aside so it can't be re-applied accidentally
mv "$UNDO_LOG" "$UNDO_LOG.applied-$(date -u +%Y%m%dT%H%M%SZ)"

echo "Reverted: $REVERTED entries (skipped: $SKIPPED)"
echo "Processed log moved to: ${UNDO_LOG}.applied-*"
