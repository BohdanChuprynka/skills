#!/usr/bin/env bash
# dream-skill apply-undo.
# Reverses vault-writer.sh actions recorded in an undo log (JSONL).
# Reads entries in reverse order; for each:
#   action=append      → remove "- <content>" from <vault>/<page>
#   action=replace     → swap "- <content>" back to "- <old_content>" in <vault>/<page>
#   action=index_append → remove the inserted line from the index file
# Prints summary of reverted entries.
#
# Usage:
#   apply-undo.sh <undo-log-path>
#   apply-undo.sh --date <YYYY-MM-DD>  (resolves to ~/.claude/dream-skill/undo/<date>.jsonl)

set -euo pipefail

# Shared path-confinement guard (defends against a tampered/corrupt undo log).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/path-guard.sh"

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
      if ! ( assert_within_vault "$VAULT" "$PAGE" ) 2>/dev/null; then
        echo "apply-undo: skipping entry with unsafe path: $PAGE" >&2
        SKIPPED=$((SKIPPED + 1)); continue
      fi
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
    replace)
      VAULT=$(echo "$line" | jq -r '.vault')
      PAGE=$(echo "$line" | jq -r '.page')
      if ! ( assert_within_vault "$VAULT" "$PAGE" ) 2>/dev/null; then
        echo "apply-undo: skipping entry with unsafe path: $PAGE" >&2
        SKIPPED=$((SKIPPED + 1)); continue
      fi
      OLD=$(echo "$line" | jq -r '.old_content')
      NEW=$(echo "$line" | jq -r '.content')
      PAGE_PATH="$VAULT/$PAGE"
      # undo: find the current (post-replace) line "- $NEW" and write the original
      # "- $OLD" back. If it isn't present (already reverted / page changed), skip.
      if [ -f "$PAGE_PATH" ] && grep -Fxq -- "- $NEW" "$PAGE_PATH"; then
        # ENVIRON (not awk -v) so backslashes in the line survive verbatim.
        old="- $NEW" new="- $OLD" awk '
          BEGIN { old = ENVIRON["old"]; new = ENVIRON["new"] }
          { if ($0 == old) print new; else print }
        ' "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
        REVERTED=$((REVERTED + 1))
      else
        SKIPPED=$((SKIPPED + 1))
      fi
      ;;
    index_append)
      INDEX_FILE=$(echo "$line" | jq -r '.index_file')
      IDX_VAULT=$(echo "$line" | jq -r '.vault // empty')
      # MANDATORY confinement: index_file must resolve UNDER its stamped vault root.
      # No best-effort fallback — an entry with no/unresolvable vault, or one resolving
      # outside it, is skipped (never applied). vault-writer always stamps .vault here,
      # so this rejects only tampered/corrupt entries.
      IDX_VROOT=""
      [ -n "$IDX_VAULT" ] && IDX_VROOT="$(cd "$IDX_VAULT" 2>/dev/null && pwd -P || true)"
      IDX_DIR="$(cd "$(dirname "$INDEX_FILE")" 2>/dev/null && pwd -P || true)"
      if [ -z "$IDX_VROOT" ] || [ -z "$IDX_DIR" ]; then
        echo "apply-undo: skipping index entry (missing/unresolvable vault confinement): $INDEX_FILE" >&2
        SKIPPED=$((SKIPPED + 1)); continue
      fi
      case "$IDX_DIR/" in
        "$IDX_VROOT"/*) ;;
        *) echo "apply-undo: skipping index entry outside its vault: $INDEX_FILE" >&2; SKIPPED=$((SKIPPED + 1)); continue ;;
      esac
      if [ -L "$INDEX_FILE" ]; then
        echo "apply-undo: skipping index entry — index file is a leaf symlink: $INDEX_FILE" >&2
        SKIPPED=$((SKIPPED + 1)); continue
      fi
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
