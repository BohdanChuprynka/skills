#!/usr/bin/env bash
# Apply decisions from the web review UI.
# Reads review-decisions.json and dispatches:
#   approve → apply-decision.sh (needs_review forced false) + queue.sh remove
#   reject  → queue.sh remove + delete sidecar
#   defer   → no-op (stays in queue for next run)
#
# Usage:
#   apply-review-decisions.sh \
#     --decisions <path-to-review-decisions.json> \
#     --sidecars-dir <path-to-sidecars-dir> \
#     --undo-log <path> \
#     [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE_SH="$SCRIPT_DIR/queue.sh"
APPLY_SH="$SCRIPT_DIR/apply-decision.sh"

DECISIONS=""
SIDECARS_DIR="${DREAM_HOME:-$HOME/.claude/dream-skill}/queue/sidecars"
UNDO_LOG=""
DRY_RUN=0

die() { echo "apply-review-decisions: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --decisions)   DECISIONS="$2";   shift 2 ;;
    --sidecars-dir) SIDECARS_DIR="$2"; shift 2 ;;
    --undo-log)    UNDO_LOG="$2";    shift 2 ;;
    --dry-run)     DRY_RUN=1;        shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$DECISIONS" ] || die "missing --decisions"
[ -n "$UNDO_LOG"  ] || die "missing --undo-log"
[ -f "$DECISIONS" ] || { echo "apply-review-decisions: no decisions file, nothing to do" >&2; exit 0; }

APPROVED=0; REJECTED=0; DEFERRED=0; ERRORS=0
FACT_LINES=""

while IFS= read -r line; do
  cid=$(echo "$line" | jq -r '.key')
  decision=$(echo "$line" | jq -r '.value')
  sidecar="$SIDECARS_DIR/$cid.json"

  case "$decision" in

    approve)
      if [ ! -f "$sidecar" ]; then
        echo "apply-review-decisions: no sidecar for $cid — skipping approve" >&2
        ERRORS=$((ERRORS + 1))
        continue
      fi
      vault_root=$(jq -r '.vault_root // empty' "$sidecar")
      title=$(jq -r '.title // .content // ""' "$sidecar")
      target_display=$(jq -r '.target_display // ""' "$sidecar")
      [ -n "$vault_root" ] || { echo "apply-review-decisions: sidecar $cid missing vault_root" >&2; ERRORS=$((ERRORS+1)); continue; }
      [ -d "$vault_root" ] || { echo "apply-review-decisions: vault_root not found: $vault_root" >&2; ERRORS=$((ERRORS+1)); continue; }

      # Write patched decision (needs_review=false so apply-decision writes to vault)
      PATCHED=$(mktemp)
      jq 'del(.candidate_id) | del(.vault_root) | del(.title) | del(.target_display) | .needs_review = false' \
        "$sidecar" > "$PATCHED"

      if [ "$DRY_RUN" = "1" ]; then
        echo "apply-review-decisions [dry-run]: would approve $cid → $vault_root"
        rm -f "$PATCHED"
      else
        fact=$("$APPLY_SH" --vault "$vault_root" --decision "$PATCHED" --undo-log "$UNDO_LOG" 2>/dev/null || true)
        rm -f "$PATCHED"
        [ -n "$fact" ] && FACT_LINES="${FACT_LINES}${fact}"$'\n'
        # Remove from queue
        target_arg="${target_display:-}"
        if [ -n "$title" ] && [ -n "$target_arg" ]; then
          "$QUEUE_SH" remove --title "$title" --target "$target_arg" 2>/dev/null || true
        fi
        rm -f "$sidecar"
      fi
      APPROVED=$((APPROVED + 1))
      ;;

    reject)
      if [ -f "$sidecar" ]; then
        title=$(jq -r '.title // .content // ""' "$sidecar")
        target_display=$(jq -r '.target_display // ""' "$sidecar")
        if [ -n "$title" ] && [ -n "$target_display" ] && [ "$DRY_RUN" != "1" ]; then
          "$QUEUE_SH" remove --title "$title" --target "$target_display" 2>/dev/null || true
          rm -f "$sidecar"
        fi
      fi
      REJECTED=$((REJECTED + 1))
      ;;

    defer)
      DEFERRED=$((DEFERRED + 1))
      ;;

  esac
done < <(jq -c 'to_entries[]' "$DECISIONS")

echo "apply-review-decisions: approved=$APPROVED rejected=$REJECTED deferred=$DEFERRED errors=$ERRORS" >&2

# Emit accumulated fact lines to stdout for the receipt
printf '%s' "$FACT_LINES"
