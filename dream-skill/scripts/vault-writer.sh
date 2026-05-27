#!/usr/bin/env bash
# dream-skill vault-writer.
# Add-only writes: appends content under a section heading; creates the
# section if absent; never overwrites or deletes existing content.
# Idempotent: identical content in the same section is not re-appended.
# Optionally updates the vault's wiki/index.md with an idempotent link
# and records every change to an undo log (JSONL) for apply-undo.sh.
#
# Usage:
#   vault-writer.sh \
#     --vault <vault-root> \
#     --page <relative-path> \
#     --section <header-text> \
#     --content <text> \
#     [--undo-log <path>] \
#     [--index-label <text>] \
#     [--index-desc <text>] \
#     [--no-index-update]

set -euo pipefail

VAULT=""
PAGE=""
SECTION=""
CONTENT=""
UNDO_LOG=""
INDEX_LABEL=""
INDEX_DESC=""
UPDATE_INDEX=1

die() { echo "vault-writer: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --page) PAGE="$2"; shift 2 ;;
    --section) SECTION="$2"; shift 2 ;;
    --content) CONTENT="$2"; shift 2 ;;
    --undo-log) UNDO_LOG="$2"; shift 2 ;;
    --index-label) INDEX_LABEL="$2"; shift 2 ;;
    --index-desc) INDEX_DESC="$2"; shift 2 ;;
    --no-index-update) UPDATE_INDEX=0; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$VAULT" ]   || die "missing --vault"
[ -n "$PAGE" ]    || die "missing --page"
[ -n "$SECTION" ] || die "missing --section"
[ -n "$CONTENT" ] || die "missing --content"
[ -d "$VAULT" ]   || die "vault dir not found: $VAULT"

PAGE_PATH="$VAULT/$PAGE"
mkdir -p "$(dirname "$PAGE_PATH")"

# --- ensure page exists ----------------------------------------------------
if [ ! -f "$PAGE_PATH" ]; then
  echo "# $(basename "$PAGE" .md | tr '-' ' ' | sed 's/.*/\u&/')" > "$PAGE_PATH"
fi

# --- append content under section (idempotent) -----------------------------
# Idempotency: skip if exact line already present in the page (any section).
APPEND_LINE="- $CONTENT"

if grep -Fxq -- "$APPEND_LINE" "$PAGE_PATH"; then
  : # already present, no-op
else
  if grep -Fxq -- "## $SECTION" "$PAGE_PATH"; then
    # Section exists → append immediately under it, before next ## or EOF.
    # awk: emit lines as-is; after finding our section, on the NEXT blank
    # line or next ## or EOF, insert the new line.
    awk -v section="## $SECTION" -v newline="$APPEND_LINE" '
      BEGIN { inserted = 0; in_section = 0 }
      {
        if ($0 == section) { print; in_section = 1; next }
        if (in_section && !inserted && /^## / && $0 != section) {
          print newline
          print ""
          inserted = 1
          in_section = 0
        }
        print
      }
      END {
        if (in_section && !inserted) {
          print newline
        }
      }
    ' "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
  else
    # Section doesn't exist → append new section to end of page.
    {
      echo ""
      echo "## $SECTION"
      echo ""
      echo "$APPEND_LINE"
    } >> "$PAGE_PATH"
  fi
fi

# --- undo log --------------------------------------------------------------
if [ -n "$UNDO_LOG" ]; then
  mkdir -p "$(dirname "$UNDO_LOG")"
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # JSON-escape content (basic: backslash + double-quote)
  ESC_CONTENT=$(printf '%s' "$CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ESC_SECTION=$(printf '%s' "$SECTION" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"timestamp":"%s","vault":"%s","page":"%s","section":"%s","content":"%s","action":"append"}\n' \
    "$TS" "$VAULT" "$PAGE" "$ESC_SECTION" "$ESC_CONTENT" >> "$UNDO_LOG"
fi

# --- index update (idempotent) ---------------------------------------------
if [ "$UPDATE_INDEX" = "1" ] && [ -n "$INDEX_LABEL" ]; then
  # Resolve index file: prefer <subdir>/wiki/index.md, fallback <subdir>/index.md
  PAGE_DIR=$(dirname "$PAGE")
  INDEX_FILE=""
  for candidate in "$VAULT/$PAGE_DIR/index.md" "$VAULT/wiki/index.md" "$VAULT/index.md"; do
    if [ -f "$candidate" ]; then INDEX_FILE="$candidate"; break; fi
  done

  if [ -n "$INDEX_FILE" ]; then
    BASENAME=$(basename "$PAGE")
    # Idempotent: skip if any reference to the page filename already exists
    # (either markdown link or Obsidian wikilink)
    if grep -q "$BASENAME" "$INDEX_FILE" || grep -q "\[\[${BASENAME%.md}\]\]" "$INDEX_FILE"; then
      : # already linked
    else
      LINE="- [$INDEX_LABEL]($BASENAME)"
      [ -n "$INDEX_DESC" ] && LINE="$LINE — $INDEX_DESC"
      echo "$LINE" >> "$INDEX_FILE"

      # Log the index edit too
      if [ -n "$UNDO_LOG" ]; then
        ESC_LABEL=$(printf '%s' "$INDEX_LABEL" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"timestamp":"%s","index_file":"%s","line":"%s","action":"index_append"}\n' \
          "$TS" "$INDEX_FILE" "$LINE" >> "$UNDO_LOG"
      fi
    fi
  fi
fi

exit 0
