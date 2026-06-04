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
#   $REPORTS_DIR/<date>.md   — full receipt
#   $REPORTS_DIR/index.md    — one-line per run summary (idempotent append)
#
# --dry-run: write receipt to stdout only; skip index.md update.
# Always exits 0 on best-effort rendering errors; exits 1 only on missing input.

set -uo pipefail

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
DATE=$(printf '%s' "$SUMMARY"        | jq -r '.date')
WIN_START=$(printf '%s' "$SUMMARY"   | jq -r '.window_start')
WIN_END=$(printf '%s' "$SUMMARY"     | jq -r '.window_end')
CHATS=$(printf '%s' "$SUMMARY"       | jq -r '.chats_scanned')

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

RECEIPT_FILE="$RUNS_DIR/${DATE}.md"
INDEX_FILE="$RUNS_DIR/index.md"

# ── count facts by action + review_status (overview §8.8) ───────────────────
# Written    = review_status=="written" AND action IN (new, supersede)
# Superseded = review_status=="written" AND action=="contradict"
# Queued     = review_status=="queued"
# Skipped    = action=="duplicate" (or review_status=="skipped")
N_WRITTEN=$(printf '%s' "$SUMMARY" | jq '[.facts[] | select(.review_status == "written" and (.action == "new" or .action == "supersede"))] | length')
N_SUPERSEDED=$(printf '%s' "$SUMMARY" | jq '[.facts[] | select(.review_status == "written" and .action == "contradict")] | length')
N_QUEUED=$(printf '%s' "$SUMMARY"    | jq '[.facts[] | select(.review_status == "queued")] | length')
N_SKIPPED=$(printf '%s' "$SUMMARY"   | jq '[.facts[] | select(.action == "duplicate" or .review_status == "skipped")] | length')
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
  printf 'window: %s → %s\n' "$WIN_START" "$WIN_END"
  printf 'chats_scanned: %s\n' "$CHATS"
  printf -- '---\n\n'
  printf '# Dream run — %s\n\n' "$DATE"

  # Written section (overview §8.8): review_status=="written" AND action IN (new, supersede)
  printf '## Written\n'
  printf '%s' "$SUMMARY" | jq -r --arg undo "$RUN_ID" '
    .facts[] | select(.review_status == "written" and (.action == "new" or .action == "supersede"))
    | if .action == "supersede" then
        "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — replaced \"\(.old_content // "?")\" → \"\(.content)\" *(undo: \($undo))*"
      else
        "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" *(undo: \($undo))*"
      end
  ' || true
  printf '\n'

  # Skipped section (overview §8.8): action=="duplicate" or review_status=="skipped"
  # (placed before Superseded so that grep -A5 on Written does not spill into Superseded content)
  printf '## Skipped (duplicate / low-confidence)\n'
  printf '%s' "$SUMMARY" | jq -r '
    .facts[] | select(.action == "duplicate" or .review_status == "skipped")
    | "- \"\(.content)\" — already present in \(.target | gsub("\\.md$";"") | "[[" + . + "]]")"
  ' || true
  printf '\n'

  # Queued section (overview §8.8): review_status=="queued"
  printf '## Queued for review\n'
  printf '%s' "$SUMMARY" | jq -r '
    .facts[] | select(.review_status == "queued")
    | "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" (\(.queue_bucket // "uncertain"); confidence: \(.confidence // "?")) → `queue.sh` bucket: \(.queue_bucket // "uncertain")"
  ' || true
  printf '\n'

  # Superseded section (overview §8.8): review_status=="written" AND action=="contradict"
  # (the old line struck via stale when a contradict was applied)
  # (placed last so grep -A5 on Written cannot reach this section's content)
  printf '## Superseded\n'
  printf '%s' "$SUMMARY" | jq -r --arg undo "$RUN_ID" '
    .facts[] | select(.review_status == "written" and .action == "contradict")
    | "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" marked stale *(undo: \($undo))*"
  ' || true
  printf '\n'
}

if [ "$DRY_RUN" -eq 1 ]; then
  render_receipt
  exit 0
fi

render_receipt > "$RECEIPT_FILE"

# ── idempotent one-line append to index.md ────────────────────────────────────
RUNS_BASENAME=$(basename "$RUNS_DIR")
INDEX_LINE="- ${DATE} | ${CHATS} chats | ${N_WRITTEN_CLEAN} written · ${N_SUPERSEDED} superseded · ${N_QUEUED} queued · ${N_SKIPPED} skipped → [[${RUNS_BASENAME}/${DATE}]]"

if [ ! -f "$INDEX_FILE" ]; then
  printf '# Dream runs index\n\n' > "$INDEX_FILE"
fi

# Only append if this date is not already in the index (idempotent)
if ! grep -qF "[[${RUNS_BASENAME}/${DATE}]]" "$INDEX_FILE" 2>/dev/null; then
  printf '%s\n' "$INDEX_LINE" >> "$INDEX_FILE"
fi
