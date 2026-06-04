#!/usr/bin/env bash
# dream-skill vault-writer.
# Writes a fact to a vault page in one of three modes (--mode, default "append"):
#   append  — add "- <content>" under a section heading; create the section if
#             absent; idempotent (identical line not re-appended). Never alters
#             or deletes existing lines.
#   replace — swap an exact existing line "- <old-content>" for "- <content>".
#   stale   — strike through an exact existing line and mark it superseded:
#             "- ~~<old-content>~~ <!-- superseded <YYYY-MM-DD> -->".
# replace and stale require --old-content. Only append updates wiki/index.md
# (idempotent link). Every change is recorded to an undo log (JSONL) for
# apply-undo.sh.
#
# Usage:
#   vault-writer.sh \
#     --vault <vault-root> \
#     --page <relative-path> \
#     --section <header-text> \
#     --content <text> \
#     [--mode append|replace|stale] \
#     [--old-content <text>] \
#     [--undo-log <path>] \
#     [--index-label <text>] \
#     [--index-desc <text>] \
#     [--no-index-update] \
#     [--dry-run]

set -euo pipefail

# Shared path-confinement guard (vault page paths originate from untrusted LLM output).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/path-guard.sh"

VAULT=""
PAGE=""
SECTION=""
CONTENT=""
UNDO_LOG=""
INDEX_LABEL=""
INDEX_DESC=""
UPDATE_INDEX=1
MODE="append"
OLD_CONTENT=""
DRY_RUN=0

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
    --mode) MODE="$2"; shift 2 ;;
    --old-content) OLD_CONTENT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$VAULT" ]   || die "missing --vault"
[ -n "$PAGE" ]    || die "missing --page"
[ -n "$SECTION" ] || die "missing --section"
[ -n "$CONTENT" ] || die "missing --content"
[ -d "$VAULT" ]   || die "vault dir not found: $VAULT"

case "$MODE" in
  append|replace|stale) ;;
  *) die "invalid --mode: $MODE (expected append|replace|stale)" ;;
esac
if [ "$MODE" != "append" ]; then
  [ -n "$OLD_CONTENT" ] || die "--mode $MODE requires --old-content"
fi

# Confine the write to the vault root — $PAGE comes from LLM routing output (untrusted).
assert_within_vault "$VAULT" "$PAGE"

PAGE_PATH="$VAULT/$PAGE"

# --- dry-run: print intended change and exit without any file mutation ------
if [ "$DRY_RUN" = "1" ]; then
  echo "vault-writer [dry-run]: mode=$MODE page=$PAGE_PATH section=$SECTION"
  echo "  content:     $CONTENT"
  [ -n "$OLD_CONTENT" ] && echo "  old_content: $OLD_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$PAGE_PATH")"

# --- per-page mutex (mkdir is atomic on POSIX) -----------------------------
# Two concurrent runs (e.g., same chat closed in two windows) writing the
# same page would race read-modify-write and clobber each other. Serialize
# via mkdir lock. Up to ~2s wait, then bail safely.
if command -v shasum >/dev/null 2>&1; then
  PAGE_HASH=$(printf '%s' "$PAGE_PATH" | shasum -a 1 | awk '{print $1}')
else
  PAGE_HASH=$(printf '%s' "$PAGE_PATH" | cksum | awk '{print $1}')
fi
LOCK_PATH="${DREAM_VAULT_LOCK_DIR:-/tmp/dream-vault-locks}/$PAGE_HASH"
mkdir -p "$(dirname "$LOCK_PATH")" 2>/dev/null || true

LOCK_RETRIES=20
while ! mkdir "$LOCK_PATH" 2>/dev/null; do
  LOCK_RETRIES=$((LOCK_RETRIES - 1))
  if [ "$LOCK_RETRIES" -le 0 ]; then
    echo "vault-writer: lock timeout on $PAGE_PATH" >&2
    exit 1
  fi
  sleep 0.1
done
trap 'rmdir "$LOCK_PATH" 2>/dev/null || true' EXIT

# Defense-in-depth: never write THROUGH a symlinked page target. The guard already
# rejects this, but the create-if-missing redirect below would otherwise follow a
# symlink out of the vault, so refuse here too.
[ -L "$PAGE_PATH" ] && die "refusing to write through symlinked page: $PAGE"

# --- ensure page exists ----------------------------------------------------
if [ ! -f "$PAGE_PATH" ]; then
  echo "# $(basename "$PAGE" .md | tr '-' ' ' | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" > "$PAGE_PATH"
fi

# --- append content under section (idempotent) -----------------------------
# Idempotency: skip if exact line already present in the page (any section).
APPEND_LINE="- $CONTENT"

if [ "$MODE" = "append" ]; then
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
else
  # replace / stale: edit an existing exact line "- $OLD_CONTENT"
  OLD_LINE="- $OLD_CONTENT"
  if [ "$MODE" = "stale" ]; then
    FINAL_CONTENT="~~${OLD_CONTENT}~~ <!-- superseded $(date +%F) -->"
  else
    FINAL_CONTENT="$CONTENT"
  fi
  NEW_LINE="- $FINAL_CONTENT"

  if grep -Fxq -- "$OLD_LINE" "$PAGE_PATH"; then
    awk -v old="$OLD_LINE" -v new="$NEW_LINE" '
      { if ($0 == old) print new; else print }
    ' "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
  elif grep -Fxq -- "$NEW_LINE" "$PAGE_PATH"; then
    : # already in target state — idempotent no-op
  else
    die "replace: old content not found in $PAGE: $OLD_CONTENT"
  fi
fi

# --- undo log --------------------------------------------------------------
if [ -n "$UNDO_LOG" ]; then
  mkdir -p "$(dirname "$UNDO_LOG")"
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$MODE" = "append" ]; then
    jq -cn --arg timestamp "$TS" --arg vault "$VAULT" --arg page "$PAGE" \
      --arg section "$SECTION" --arg content "$CONTENT" \
      '{"timestamp":$timestamp,"vault":$vault,"page":$page,"section":$section,"content":$content,"action":"append"}' \
      >> "$UNDO_LOG"
  else
    jq -cn --arg timestamp "$TS" --arg vault "$VAULT" --arg page "$PAGE" \
      --arg section "$SECTION" --arg old_content "$OLD_CONTENT" --arg content "$FINAL_CONTENT" \
      '{"timestamp":$timestamp,"vault":$vault,"page":$page,"section":$section,"old_content":$old_content,"content":$content,"action":"replace"}' \
      >> "$UNDO_LOG"
  fi
fi

# --- index update (idempotent, append mode only) ---------------------------
if [ "$MODE" = "append" ] && [ "$UPDATE_INDEX" = "1" ] && [ -n "$INDEX_LABEL" ]; then
  # Resolve index file: prefer <subdir>/wiki/index.md, fallback <subdir>/index.md
  PAGE_DIR=$(dirname "$PAGE")
  INDEX_FILE=""
  for candidate in "$VAULT/$PAGE_DIR/index.md" "$VAULT/wiki/index.md" "$VAULT/index.md"; do
    if [ -f "$candidate" ]; then INDEX_FILE="$candidate"; break; fi
  done

  if [ -n "$INDEX_FILE" ]; then
    # Confine: reject leaf-symlink index files and any that resolve outside the vault.
    # Skip the update rather than die — page write already succeeded.
    _IDX_SAFE=1
    if [ -L "$INDEX_FILE" ]; then
      echo "vault-writer: skipping index update — index file is a leaf symlink" >&2
      _IDX_SAFE=0
    else
      _IVREAL="$(cd "$VAULT" 2>/dev/null && pwd -P || true)"
      _IDXDIR="$(cd "$(dirname "$INDEX_FILE")" 2>/dev/null && pwd -P || true)"
      case "$_IDXDIR/" in
        "$_IVREAL"/*) ;;
        *) echo "vault-writer: skipping index update — index file outside vault root" >&2; _IDX_SAFE=0 ;;
      esac
    fi
    if [ "$_IDX_SAFE" = "1" ]; then
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
          jq -cn --arg timestamp "$TS" --arg vault "$VAULT" \
            --arg index_file "$INDEX_FILE" --arg line "$LINE" \
            '{"timestamp":$timestamp,"vault":$vault,"index_file":$index_file,"line":$line,"action":"index_append"}' \
            >> "$UNDO_LOG"
        fi
      fi
    fi
  fi
fi

exit 0
