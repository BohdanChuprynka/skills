#!/usr/bin/env bash
# dream-skill vault-writer.
# Writes a fact to a vault page in one of four modes (--mode, default "append"):
#   append  — add "- <content>" under a section heading; create the section if
#             absent; idempotent (identical line not re-appended). Never alters
#             or deletes existing lines.
#   replace — swap an exact existing line "- <old-content>" for "- <content>".
#   remove  — remove one exact "- <content>" line. Reserved for reviewed,
#             transactional cleanup manifests; never used by normal APPLY.
#   stale   — strike through an exact existing line and mark it superseded:
#             "- ~~<old-content>~~ <!-- superseded <YYYY-MM-DD> -->".
# replace and stale require --old-content. Only append updates wiki/index.md
# (idempotent link). Every change is recorded to an undo log (JSONL) for
# apply-undo.sh.
#
# Freshness contract: when a page begins with a valid YAML frontmatter block,
# every real mutation updates (or adds) `updated: YYYY-MM-DD` inside it. Pages
# without leading YAML are deliberately left without YAML; Dream must not
# silently impose a schema on legacy/free-form notes. The prior field state is
# stored in the same undo entry as the content mutation.
#
# Usage:
#   vault-writer.sh \
#     --vault <vault-root> \
#     --page <relative-path> \
#     --section <header-text> \
#     --content <text> \
#     [--mode append|replace|remove|stale] \
#     [--old-content <text>] \
#     [--undo-log <path>] \
#     [--run-id <run-id>] \
#     [--candidate-id <candidate-id>] \
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
RUN_ID=""
CANDIDATE_ID=""

die() { echo "vault-writer: $*" >&2; exit 1; }

# Set FM_PRESENT_BEFORE / FM_HAD_UPDATED_BEFORE / FM_UPDATED_BEFORE for FILE.
# Only a leading, closed `---` block counts as YAML frontmatter.
_capture_frontmatter_state() {
  local file="$1" closing=""
  FM_PRESENT_BEFORE=false
  FM_HAD_UPDATED_BEFORE=false
  FM_UPDATED_BEFORE=""
  [ -f "$file" ] || return 0
  [ "$(sed -n '1p' "$file")" = "---" ] || return 0
  closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$file")
  [ -n "$closing" ] || return 0
  FM_PRESENT_BEFORE=true
  FM_UPDATED_BEFORE=$(awk '
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && /^updated:[[:space:]]*/ { print; exit }
  ' "$file")
  if [ -n "$FM_UPDATED_BEFORE" ]; then
    FM_HAD_UPDATED_BEFORE=true
  fi
}

# Write INPUT to OUTPUT while refreshing only the first `updated:` field in a
# known-valid leading frontmatter block. All other frontmatter lines survive.
_write_with_freshness() {
  local input="$1" output="$2" today="$3"
  if [ "$FM_PRESENT_BEFORE" != "true" ]; then
    cp "$input" "$output"
    return 0
  fi
  updated_line="updated: $today" awk '
    BEGIN { replacement = ENVIRON["updated_line"]; in_fm=0; seen=0 }
    NR == 1 && $0 == "---" { in_fm=1; print; next }
    in_fm && $0 == "---" {
      if (!seen) print replacement
      in_fm=0
      print
      next
    }
    in_fm && /^updated:[[:space:]]*/ && !seen {
      print replacement
      seen=1
      next
    }
    { print }
  ' "$input" > "$output"
}

_frontmatter_json() {
  local applied_date="$1"
  jq -cn \
    --argjson present "$FM_PRESENT_BEFORE" \
    --argjson had_updated "$FM_HAD_UPDATED_BEFORE" \
    --arg updated_before "$FM_UPDATED_BEFORE" \
    --arg applied_date "$applied_date" \
    '{present_before:$present,
      had_updated_before:$had_updated,
      updated_before:(if $had_updated then $updated_before else null end),
      updated_applied:(if $present then $applied_date else null end)}'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --page) PAGE="$2"; shift 2 ;;
    --section) SECTION="$2"; shift 2 ;;
    --content) CONTENT="$2"; shift 2 ;;
    --undo-log) UNDO_LOG="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --candidate-id) CANDIDATE_ID="$2"; shift 2 ;;
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

# New undo records are attributable even when this low-level helper is invoked
# directly by an older integration. Production callers always pass the real
# run/candidate IDs; the deterministic legacy IDs keep existing manual tooling
# inspectable without allowing blank provenance fields into new records.
if [ -n "$UNDO_LOG" ]; then
  if [ -z "$RUN_ID" ]; then
    if command -v shasum >/dev/null 2>&1; then
      _legacy_run_hash=$(printf '%s' "$UNDO_LOG" | shasum -a 256 | awk '{print substr($1,1,16)}')
    else
      _legacy_run_hash=$(printf '%s' "$UNDO_LOG" | cksum | awk '{print $1}')
    fi
    RUN_ID="legacy-${_legacy_run_hash}"
  fi
  if [ -z "$CANDIDATE_ID" ]; then
    if command -v shasum >/dev/null 2>&1; then
      _legacy_candidate_hash=$(printf '%s\0%s\0%s\0%s\0%s' "$VAULT" "$PAGE" "$SECTION" "$MODE" "$CONTENT" \
        | shasum -a 256 | awk '{print substr($1,1,24)}')
    else
      _legacy_candidate_hash=$(printf '%s\0%s\0%s\0%s\0%s' "$VAULT" "$PAGE" "$SECTION" "$MODE" "$CONTENT" \
        | cksum | awk '{print $1}')
    fi
    CANDIDATE_ID="legacy-${_legacy_candidate_hash}"
  fi
fi

case "$MODE" in
  append|replace|remove|stale) ;;
  *) die "invalid --mode: $MODE (expected append|replace|remove|stale)" ;;
esac
if [ "$MODE" = "replace" ] || [ "$MODE" = "stale" ]; then
  [ -n "$OLD_CONTENT" ] || die "--mode $MODE requires --old-content"
fi

# One decision owns one Markdown line. Reject multiline payloads before any
# mutation; they previously produced malformed list entries and unsafe undo.
case "$CONTENT$OLD_CONTENT" in
  *$'\n'*|*$'\r'*) die "content and old-content must each be one line" ;;
esac

# MAP/Reconcile occasionally return a pre-bulleted additive fact. Normalize it
# here so retries cannot create '- - fact' contamination.
if [ "$MODE" = "append" ] || [ "$MODE" = "remove" ]; then
  while [[ "$CONTENT" == "- "* ]]; do CONTENT="${CONTENT#- }"; done
  [ -n "$CONTENT" ] || die "$MODE content is empty after bullet normalization"
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
# User-scoped lock dir (uid suffix) instead of a world-shared /tmp/dream-vault-locks
# path — avoids cross-user collisions and symlink-bait on shared hosts.
LOCK_BASE="${DREAM_VAULT_LOCK_DIR:-${TMPDIR:-/tmp}/dream-vault-locks-$(id -u)}"
LOCK_PATH="$LOCK_BASE/$PAGE_HASH"
mkdir -p "$LOCK_BASE" 2>/dev/null || true

LOCK_RETRIES=20
while ! mkdir "$LOCK_PATH" 2>/dev/null; do
  # Reclaim a stale lock: if the recorded holder PID is gone (crash / SIGKILL
  # bypassed the EXIT trap), the lock would otherwise wedge every future run.
  # Serialize the reclaim behind its own guard so two waiters can't both delete
  # a directory the other just re-acquired (which would double-acquire the lock).
  if mkdir "$LOCK_PATH.reclaim" 2>/dev/null; then
    holder=""
    [ -f "$LOCK_PATH/pid" ] && holder="$(cat "$LOCK_PATH/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$LOCK_PATH" 2>/dev/null || true
    fi
    rmdir "$LOCK_PATH.reclaim" 2>/dev/null || true
  fi
  LOCK_RETRIES=$((LOCK_RETRIES - 1))
  if [ "$LOCK_RETRIES" -le 0 ]; then
    echo "vault-writer: lock timeout on $PAGE_PATH" >&2
    exit 1
  fi
  sleep 0.1
done
# Record holder PID atomically (temp + mv) so a waiter never reads a partial pid.
printf '%s\n' "$$" > "$LOCK_PATH/.pid.tmp" 2>/dev/null \
  && mv -f "$LOCK_PATH/.pid.tmp" "$LOCK_PATH/pid" 2>/dev/null || true
trap 'rm -rf "$LOCK_PATH" 2>/dev/null || true; rm -f "${MUTATED_TMP:-}" "${FRESH_TMP:-}" "${INDEX_MUTATED_TMP:-}" "${INDEX_FRESH_TMP:-}" 2>/dev/null || true' EXIT

# Defense-in-depth: never write THROUGH a symlinked page target. The guard already
# rejects this, but the create-if-missing redirect below would otherwise follow a
# symlink out of the vault, so refuse here too.
[ -L "$PAGE_PATH" ] && die "refusing to write through symlinked page: $PAGE"

# --- ensure page exists ----------------------------------------------------
CHANGED=0
if [ ! -f "$PAGE_PATH" ]; then
  if [ "$MODE" != "append" ]; then
    die "target page does not exist for mode=$MODE: $PAGE"
  fi
  echo "# $(basename "$PAGE" .md | tr '-' ' ' | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" > "$PAGE_PATH"
fi

_capture_frontmatter_state "$PAGE_PATH"
TODAY=$(date +%F)
MUTATED_TMP="$PAGE_PATH.mutate.$$"
FRESH_TMP="$PAGE_PATH.fresh.$$"

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
      # Pass section/content via the environment (ENVIRON), NOT awk -v: -v
      # processes C-style backslash escapes (\n \t \\ \d …), which corrupts any
      # fact containing a backslash and breaks the grep -Fxq idempotency above.
      section="## $SECTION" newline="$APPEND_LINE" awk '
        BEGIN { inserted = 0; in_section = 0; section = ENVIRON["section"]; newline = ENVIRON["newline"] }
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
      ' "$PAGE_PATH" > "$MUTATED_TMP"
    else
      # Section doesn't exist → append new section to end of page.
      {
        cat "$PAGE_PATH"
        echo ""
        echo "## $SECTION"
        echo ""
        echo "$APPEND_LINE"
      } > "$MUTATED_TMP"
    fi
    CHANGED=1
  fi
elif [ "$MODE" = "remove" ]; then
  MATCH_COUNT=$(grep -Fxc -- "$APPEND_LINE" "$PAGE_PATH" || true)
  if [ "$MATCH_COUNT" -gt 1 ]; then
    die "remove: content occurs more than once in $PAGE: $CONTENT"
  elif [ "$MATCH_COUNT" = "1" ]; then
    REMOVED_LINE_NUMBER=$(grep -Fnx -- "$APPEND_LINE" "$PAGE_PATH" | cut -d: -f1)
    REMOVED_PREVIOUS_LINE=""
    REMOVED_NEXT_LINE=""
    if [ "$REMOVED_LINE_NUMBER" -gt 1 ]; then
      REMOVED_PREVIOUS_LINE=$(sed -n "$((REMOVED_LINE_NUMBER - 1))p" "$PAGE_PATH")
    fi
    REMOVED_NEXT_LINE=$(sed -n "$((REMOVED_LINE_NUMBER + 1))p" "$PAGE_PATH")
    remove_line="$APPEND_LINE" awk '
      BEGIN { needle=ENVIRON["remove_line"]; removed=0 }
      !removed && $0 == needle { removed=1; next }
      { print }
      END { if (!removed) exit 42 }
    ' "$PAGE_PATH" > "$MUTATED_TMP"
    CHANGED=1
  else
    : # already absent — idempotent no-op
  fi
else
  # replace / stale: old-content and content are exact complete Markdown lines.
  OLD_LINE="$OLD_CONTENT"
  if [ "$MODE" = "stale" ]; then
    case "$OLD_CONTENT" in
      "- "*) FINAL_CONTENT="- ~~${OLD_CONTENT#- }~~ <!-- superseded $(date +%F) -->" ;;
      *) FINAL_CONTENT="~~${OLD_CONTENT}~~ <!-- superseded $(date +%F) -->" ;;
    esac
  else
    FINAL_CONTENT="$CONTENT"
  fi
  NEW_LINE="$FINAL_CONTENT"

  if grep -Fxq -- "$OLD_LINE" "$PAGE_PATH"; then
    # ENVIRON (not awk -v) so backslashes in the line content survive verbatim.
    old="$OLD_LINE" new="$NEW_LINE" awk '
      BEGIN { old = ENVIRON["old"]; new = ENVIRON["new"] }
      { if ($0 == old) print new; else print }
    ' "$PAGE_PATH" > "$MUTATED_TMP"
    CHANGED=1
  elif grep -Fxq -- "$NEW_LINE" "$PAGE_PATH"; then
    : # already in target state — idempotent no-op
  else
    die "replace: old content not found in $PAGE: $OLD_CONTENT"
  fi
fi

# Commit content + freshness as one page replacement. A reader never observes
# the new fact with stale frontmatter (or vice versa).
if [ "$CHANGED" = "1" ]; then
  _write_with_freshness "$MUTATED_TMP" "$FRESH_TMP" "$TODAY"
  mv -f "$FRESH_TMP" "$PAGE_PATH"
fi
rm -f "$MUTATED_TMP" "$FRESH_TMP"

# --- undo log --------------------------------------------------------------
# Log only real mutations. A no-op retry must not create an undo entry that can
# later remove or overwrite a fact written by an earlier successful attempt.
if [ -n "$UNDO_LOG" ] && [ "$CHANGED" = "1" ]; then
  mkdir -p "$(dirname "$UNDO_LOG")"
  chmod 700 "$(dirname "$UNDO_LOG")" 2>/dev/null || true
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  FM_JSON=$(_frontmatter_json "$TODAY")
  if [ "$MODE" = "append" ]; then
    jq -cn --arg timestamp "$TS" --arg vault "$VAULT" --arg page "$PAGE" \
      --arg section "$SECTION" --arg content "$CONTENT" \
      --arg run_id "$RUN_ID" --arg candidate_id "$CANDIDATE_ID" \
      --argjson frontmatter "$FM_JSON" \
      '{"timestamp":$timestamp,"run_id":$run_id,"candidate_id":$candidate_id,"vault":$vault,"page":$page,"section":$section,"content":$content,"action":"append","frontmatter":$frontmatter}' \
      >> "$UNDO_LOG"
  elif [ "$MODE" = "remove" ]; then
    jq -cn --arg timestamp "$TS" --arg vault "$VAULT" --arg page "$PAGE" \
      --arg section "$SECTION" --arg content "$CONTENT" \
      --arg previous_line "${REMOVED_PREVIOUS_LINE:-}" --arg next_line "${REMOVED_NEXT_LINE:-}" \
      --argjson line_number "${REMOVED_LINE_NUMBER:-0}" \
      --arg run_id "$RUN_ID" --arg candidate_id "$CANDIDATE_ID" \
      --argjson frontmatter "$FM_JSON" \
      '{"timestamp":$timestamp,"run_id":$run_id,"candidate_id":$candidate_id,"vault":$vault,"page":$page,"section":$section,"content":$content,"action":"remove","line_number_before":$line_number,"previous_line":$previous_line,"next_line":$next_line,"frontmatter":$frontmatter}' \
      >> "$UNDO_LOG"
  else
    jq -cn --arg timestamp "$TS" --arg vault "$VAULT" --arg page "$PAGE" \
      --arg section "$SECTION" --arg old_content "$OLD_CONTENT" --arg content "$FINAL_CONTENT" \
      --arg run_id "$RUN_ID" --arg candidate_id "$CANDIDATE_ID" \
      --argjson frontmatter "$FM_JSON" \
      '{"timestamp":$timestamp,"run_id":$run_id,"candidate_id":$candidate_id,"vault":$vault,"page":$page,"section":$section,"old_content":$old_content,"content":$content,"action":"replace","frontmatter":$frontmatter}' \
      >> "$UNDO_LOG"
  fi
  chmod 600 "$UNDO_LOG" 2>/dev/null || true
fi

# --- index update (idempotent, append mode only) ---------------------------
if [ "$MODE" = "append" ] && [ "$CHANGED" = "1" ] && [ "$UPDATE_INDEX" = "1" ] && [ -n "$INDEX_LABEL" ]; then
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
        _capture_frontmatter_state "$INDEX_FILE"
        INDEX_MUTATED_TMP="$INDEX_FILE.mutate.$$"
        INDEX_FRESH_TMP="$INDEX_FILE.fresh.$$"
        { cat "$INDEX_FILE"; echo "$LINE"; } > "$INDEX_MUTATED_TMP"
        _write_with_freshness "$INDEX_MUTATED_TMP" "$INDEX_FRESH_TMP" "$TODAY"
        mv -f "$INDEX_FRESH_TMP" "$INDEX_FILE"
        rm -f "$INDEX_MUTATED_TMP" "$INDEX_FRESH_TMP"

        # Log the index edit too
        if [ -n "$UNDO_LOG" ]; then
          INDEX_FM_JSON=$(_frontmatter_json "$TODAY")
          jq -cn --arg timestamp "$TS" --arg vault "$VAULT" \
            --arg index_file "$INDEX_FILE" --arg line "$LINE" \
            --arg run_id "$RUN_ID" --arg candidate_id "$CANDIDATE_ID" \
            --argjson frontmatter "$INDEX_FM_JSON" \
            '{"timestamp":$timestamp,"run_id":$run_id,"candidate_id":$candidate_id,"vault":$vault,"index_file":$index_file,"line":$line,"action":"index_append","frontmatter":$frontmatter}' \
            >> "$UNDO_LOG"
          chmod 600 "$UNDO_LOG" 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

exit 0
