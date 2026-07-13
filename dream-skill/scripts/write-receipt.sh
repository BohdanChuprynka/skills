#!/usr/bin/env bash
# write-receipt.sh — render a per-run receipt from a run summary JSON (stdin).
#
# Usage:
#   <run-summary-json> | write-receipt.sh [--dry-run] [--config <path>]
#
# Environment:
#   DREAM_RUNS_DIR  — override the reports_dir from config.toml
#   DREAM_CONFIG    — path to config.toml (default: ~/.claude/dream-skill/config.toml)
#
# Output files:
#   $REPORTS_DIR/<run-id>.md — full receipt
#   $REPORTS_DIR/index.md    — one-line per run summary (idempotent append)
#
# --dry-run: write receipt to stdout only; skip index.md update.
# Exits nonzero on invalid input, unsafe run identity, or persistence failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
CONFIG_FILE="${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --config)  CONFIG_FILE="${2:-}"; shift 2 ;;
    *) echo "write-receipt.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read stdin
SUMMARY=$(cat)
[ -n "$SUMMARY" ] || { echo "write-receipt.sh: empty input on stdin" >&2; exit 1; }

# jq required for JSON parsing
command -v jq >/dev/null 2>&1 || { echo "write-receipt.sh: jq required" >&2; exit 1; }

RUN_ID=$(printf '%s' "$SUMMARY"      | jq -r '.run_id')
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || {
  echo "write-receipt.sh: summary missing run_id" >&2; exit 1;
}
case "$RUN_ID" in
  ""|[._-]*|*[!A-Za-z0-9._-]*) echo "write-receipt.sh: unsafe run_id: $RUN_ID" >&2; exit 1 ;;
esac
[ "${#RUN_ID}" -le 128 ] || { echo "write-receipt.sh: run_id is too long" >&2; exit 1; }
# Receipt date: prefer an explicit .date, else the batch end (.window_end), else today.
# Never let a missing key collapse to the literal "null" (which would misfile every
# receipt to null.md and clobber the index — see REVIEW-2026-06-04 C1).
DATE=$(printf '%s' "$SUMMARY"        | jq -r '.date // .window_end // empty')
[ -n "$DATE" ] && [ "$DATE" != "null" ] || DATE=$(date +%F)
WIN_START=$(printf '%s' "$SUMMARY"   | jq -r '.window_start')
WIN_END=$(printf '%s' "$SUMMARY"     | jq -r '.window_end')
CHATS=$(printf '%s' "$SUMMARY"       | jq -r '.chats_scanned')
UNDO_LOG=$(printf '%s' "$SUMMARY"    | jq -r '.undo_log // empty')
UNDO_HOME=$(printf '%s' "$SUMMARY"   | jq -r '.undo_home // empty')

# Modern summaries identify the concrete per-run log. Reject a mismatched path
# so a receipt can never advertise a --run-id selector that actually resolves
# to a shared dated log. Old standalone producers may omit these fields; their
# receipts still use the real --run-id interface but are labeled legacy below.
if [ -n "$UNDO_LOG" ]; then
  [ "$(basename "$UNDO_LOG")" = "${RUN_ID}.jsonl" ] || {
    echo "write-receipt.sh: undo_log is not scoped to run_id $RUN_ID" >&2; exit 1;
  }
fi
if [ -z "$UNDO_HOME" ] && [ -n "$UNDO_LOG" ]; then
  UNDO_HOME=$(dirname "$(dirname "$UNDO_LOG")")
fi
UNDO_HOME="${UNDO_HOME:-$HOME/.claude/dream-skill}"

# Resolve reports dir — parse config.toml like scripts/report.sh does
# Priority: DREAM_RUNS_DIR env var > config.toml reports_dir
RUNS_DIR="${DREAM_RUNS_DIR:-}"
if [ -z "$RUNS_DIR" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    RUNS_DIR=$(awk -F'[= "]+' '/^reports_dir/ { print $2; exit }' "$CONFIG_FILE" | tr -d ' "')
  fi
fi
# Final fallback if config missing or reports_dir absent
RUNS_DIR="${RUNS_DIR:-$HOME/.claude/dream-skill/dream-reports}"
mkdir -p "$RUNS_DIR"

RECEIPT_FILE="$RUNS_DIR/${RUN_ID}.md"
INDEX_FILE="$RUNS_DIR/index.md"

# ── count facts by action + review_status (overview §8.8) ───────────────────
# Written    = review_status=="written" AND action IN (new, supersede)
# Superseded = review_status=="written" AND action=="contradict"
# Queued     = review_status=="queued"
# Skipped    = action=="duplicate" (or review_status=="skipped")
N_WRITTEN=$(printf '%s' "$SUMMARY" | jq '[(.facts // [])[] | select(.review_status == "written" and (.action == "new" or .action == "supersede"))] | length')
N_SUPERSEDED=$(printf '%s' "$SUMMARY" | jq '[(.facts // [])[] | select(.review_status == "written" and .action == "contradict")] | length')
N_QUEUED=$(printf '%s' "$SUMMARY"    | jq '[(.facts // [])[] | select(.review_status == "queued")] | length')
N_SKIPPED=$(printf '%s' "$SUMMARY"   | jq '[(.facts // [])[] | select(.action == "duplicate" or .review_status == "skipped")] | length')
# N_WRITTEN_CLEAN = same as N_WRITTEN (Written section in index line)
N_WRITTEN_CLEAN="$N_WRITTEN"

# ── render receipt ────────────────────────────────────────────────────────────
# wiki-page → [[wikilink]] (strip .md, prepend vault/wiki prefix as-is)
wikilink() {
  printf '%s' "$1" | sed 's/\.md$//' | awk '{printf "[[%s]]", $0}'
}

render_receipt() {
  printf -- '---\n'
  printf 'date: %s\n' "$DATE"
  printf 'run_id: %s\n' "$RUN_ID"
  printf 'undo_run_id: %s\n' "$RUN_ID"
  printf 'window: %s → %s\n' "$WIN_START" "$WIN_END"
  printf 'chats_scanned: %s\n' "$CHATS"
  printf -- '---\n\n'
  printf '# Dream run — %s\n\n' "$DATE"
  printf 'Run ID: `%s`  \n' "$RUN_ID"
  if [ $((N_WRITTEN + N_SUPERSEDED)) -gt 0 ]; then
    printf 'Rollback: `%s/apply-undo.sh --home "%s" --run-id "%s"`\n\n' "$SCRIPT_DIR" "$UNDO_HOME" "$RUN_ID"
  else
    printf 'Rollback: none (this run made no vault mutations).\n\n'
  fi

  # Written section (overview §8.8): review_status=="written" AND action IN (new, supersede)
  printf '## Written\n'
  printf '%s' "$SUMMARY" | jq -r --arg undo "$RUN_ID" '
    (.facts // [])[] | select(.review_status == "written" and (.action == "new" or .action == "supersede"))
    | if .action == "supersede" then
        "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — replaced \"\(.old_content // "?")\" → \"\(.content)\" *(undo: \($undo))*"
      else
        "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" *(undo: \($undo))*"
      end
  ' || true
  printf '\n'

  # Skipped section (overview §8.8): action=="duplicate" or review_status=="skipped"
  # (placed before Superseded so that grep -A5 on Written does not spill into Superseded content)
  printf '## Skipped as duplicates\n'
  printf '%s' "$SUMMARY" | jq -r '
    (.facts // [])[] | select(.action == "duplicate" or .review_status == "skipped")
    | (.candidate_content // .content // "") as $candidate
    | (.target | gsub("\\.md$";"") | "[[" + . + "]]") as $target
    | if $candidate == "" then
        "- Duplicate already present in \($target)"
      else
        "- \"\($candidate)\" — already present in \($target)"
      end
  ' || true
  printf '\n'

  # Queued section (overview §8.8): review_status=="queued"
  printf '## Queued for review\n'
  printf '%s' "$SUMMARY" | jq -r '
    (.facts // [])[] | select(.review_status == "queued")
    | "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" (\(.queue_bucket // "uncertain"); confidence: \(.confidence // "?")) → `queue.sh` bucket: \(.queue_bucket // "uncertain")"
  ' || true
  printf '\n'

  # Audit section: memory_tier=="audit" candidates synthesized by dream-run.py —
  # recorded here for provenance but never routed, reconciled, or written to a vault.
  printf '## Audit (recorded, not written to a vault)\n'
  printf '%s' "$SUMMARY" | jq -r '
    (.facts // [])[] | select(.review_status == "audit")
    | "- \"\(.content)\" (confidence: \(.confidence // "?"))"
  ' || true
  printf '\n'

  # Superseded section (overview §8.8): review_status=="written" AND action=="contradict"
  # (the old line struck via stale when a contradict was applied)
  # (placed last so grep -A5 on Written cannot reach this section's content)
  printf '## Superseded\n'
  printf '%s' "$SUMMARY" | jq -r --arg undo "$RUN_ID" '
    (.facts // [])[] | select(.review_status == "written" and .action == "contradict")
    | "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" marked stale *(undo: \($undo))*"
  ' || true
  printf '\n'
}

if [ "$DRY_RUN" -eq 1 ]; then
  render_receipt
  exit 0
fi

# Persist the receipt through a same-directory temporary file. Refuse special
# paths up front: a directory or symlink at the run receipt path must never be
# mistaken for a successful run artifact.
if [ -e "$RECEIPT_FILE" ] && [ ! -f "$RECEIPT_FILE" ]; then
  echo "write-receipt.sh: receipt path is not a regular file: $RECEIPT_FILE" >&2
  exit 1
fi
[ ! -L "$RECEIPT_FILE" ] || {
  echo "write-receipt.sh: refusing symlinked receipt path: $RECEIPT_FILE" >&2
  exit 1
}
_receipt_tmp=$(mktemp "$RUNS_DIR/.${RUN_ID}.md.tmp.XXXXXX")
_index_tmp=""
trap 'rm -f "${_receipt_tmp:-}" "${_index_tmp:-}"' EXIT
if ! render_receipt > "$_receipt_tmp"; then
  echo "write-receipt.sh: failed to render receipt: $RECEIPT_FILE" >&2
  exit 1
fi
chmod 600 "$_receipt_tmp"
if ! mv -f -- "$_receipt_tmp" "$RECEIPT_FILE"; then
  echo "write-receipt.sh: failed to persist receipt: $RECEIPT_FILE" >&2
  exit 1
fi
_receipt_tmp=""

# ── idempotent one-line update to index.md ────────────────────────────────────
RUNS_BASENAME=$(basename "$RUNS_DIR")
INDEX_MARKER="<!-- dream-run:${RUN_ID} -->"
INDEX_LINE="- ${DATE} | ${CHATS} chats | ${N_WRITTEN_CLEAN} written · ${N_SUPERSEDED} superseded · ${N_QUEUED} queued · ${N_SKIPPED} skipped → [[${RUNS_BASENAME}/${RUN_ID}]] ${INDEX_MARKER}"

if [ -e "$INDEX_FILE" ] && [ ! -f "$INDEX_FILE" ]; then
  echo "write-receipt.sh: index path is not a regular file: $INDEX_FILE" >&2
  exit 1
fi
[ ! -L "$INDEX_FILE" ] || {
  echo "write-receipt.sh: refusing symlinked index path: $INDEX_FILE" >&2
  exit 1
}
_index_tmp=$(mktemp "$RUNS_DIR/.index.md.tmp.XXXXXX")
if [ -f "$INDEX_FILE" ] && grep -qF "$INDEX_MARKER" "$INDEX_FILE" 2>/dev/null; then
  marker="$INDEX_MARKER" replacement="$INDEX_LINE" awk '
    index($0, ENVIRON["marker"]) { print ENVIRON["replacement"]; next }
    { print }
  ' "$INDEX_FILE" > "$_index_tmp"
elif [ -f "$INDEX_FILE" ]; then
  {
    cat "$INDEX_FILE"
    printf '%s\n' "$INDEX_LINE"
  } > "$_index_tmp"
else
  {
    printf '# Dream runs index\n\n'
    printf '%s\n' "$INDEX_LINE"
  } > "$_index_tmp"
fi
chmod 600 "$_index_tmp"
if ! mv -f -- "$_index_tmp" "$INDEX_FILE"; then
  echo "write-receipt.sh: failed to persist index: $INDEX_FILE" >&2
  exit 1
fi
_index_tmp=""
