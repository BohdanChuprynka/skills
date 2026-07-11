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
#     --review-input <path-to-review-input.json> \
#     --sidecars-dir <path-to-sidecars-dir> \
#     --undo-log <path> \
#     [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE_SH="$SCRIPT_DIR/queue.sh"
APPLY_SH="$SCRIPT_DIR/apply-decision.sh"

DECISIONS=""
REVIEW_INPUT=""
SIDECARS_DIR="${DREAM_HOME:-$HOME/.claude/dream-skill}/queue/sidecars"
UNDO_LOG=""
DRY_RUN=0

die() { echo "apply-review-decisions: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --decisions)   DECISIONS="$2";   shift 2 ;;
    --review-input) REVIEW_INPUT="$2"; shift 2 ;;
    --sidecars-dir) SIDECARS_DIR="$2"; shift 2 ;;
    --undo-log)    UNDO_LOG="$2";    shift 2 ;;
    --dry-run)     DRY_RUN=1;        shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$DECISIONS" ] || die "missing --decisions"
[ -n "$REVIEW_INPUT" ] || die "missing --review-input"
[ -n "$UNDO_LOG"  ] || die "missing --undo-log"
[ -f "$DECISIONS" ] || { echo "apply-review-decisions: no decisions file, nothing to do" >&2; exit 0; }
[ -f "$REVIEW_INPUT" ] || die "review input not found: $REVIEW_INPUT"

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
      target_display=$(jq -r '.target_display // ((.vault_root // "") + "/" + (.target.page // "") + "#" + (.target.section // ""))' "$sidecar")
      [ -n "$vault_root" ] || { echo "apply-review-decisions: sidecar $cid missing vault_root" >&2; ERRORS=$((ERRORS+1)); continue; }
      [ -d "$vault_root" ] || { echo "apply-review-decisions: vault_root not found: $vault_root" >&2; ERRORS=$((ERRORS+1)); continue; }

      # Write patched decision (needs_review=false so apply-decision writes to vault)
      PATCHED=$(mktemp)
      jq 'del(.candidate_id) | del(.vault_root) | del(.title) | del(.target_display) | .needs_review = false' \
        "$sidecar" > "$PATCHED"

      if [ "$DRY_RUN" = "1" ]; then
        echo "apply-review-decisions [dry-run]: would approve $cid → $vault_root"
        rm -f "$PATCHED"
        APPROVED=$((APPROVED + 1))
      else
        apply_stdout=$(mktemp)
        apply_stderr=$(mktemp)
        if ! "$APPLY_SH" --vault "$vault_root" --decision "$PATCHED" --undo-log "$UNDO_LOG" \
          >"$apply_stdout" 2>"$apply_stderr"; then
          echo "apply-review-decisions: approve failed for $cid; queue and sidecar retained" >&2
          sed 's/^/  /' "$apply_stderr" >&2 || true
          rm -f "$PATCHED" "$apply_stdout" "$apply_stderr"
          ERRORS=$((ERRORS + 1))
          continue
        fi
        fact=$(cat "$apply_stdout")
        rm -f "$apply_stdout" "$apply_stderr"
        rm -f "$PATCHED"
        [ -n "$fact" ] && FACT_LINES="${FACT_LINES}${fact}"$'\n'
        if ! "$QUEUE_SH" remove --title "$title" --target "$target_display"; then
          echo "apply-review-decisions: write succeeded but queue removal failed for $cid; sidecar retained for idempotent retry" >&2
          ERRORS=$((ERRORS + 1))
          continue
        fi
        rm -f "$sidecar"
        APPROVED=$((APPROVED + 1))
      fi
      ;;

    reject)
      if [ -f "$sidecar" ]; then
        title=$(jq -r '.title // .content // ""' "$sidecar")
        target_display=$(jq -r '.target_display // ((.vault_root // "") + "/" + (.target.page // "") + "#" + (.target.section // ""))' "$sidecar")
        if [ -n "$title" ] && [ -n "$target_display" ] && [ "$DRY_RUN" != "1" ]; then
          if ! "$QUEUE_SH" remove --title "$title" --target "$target_display"; then
            echo "apply-review-decisions: reject queue removal failed for $cid; sidecar retained" >&2
            ERRORS=$((ERRORS + 1))
            continue
          fi
          rm -f "$sidecar"
        fi
      else
        echo "apply-review-decisions: no sidecar for rejected $cid; nothing safely removable" >&2
        ERRORS=$((ERRORS + 1))
        continue
      fi
      REJECTED=$((REJECTED + 1))
      ;;

    defer)
      DEFERRED=$((DEFERRED + 1))
      ;;

  esac
done < <(jq -c --slurpfile review "$REVIEW_INPUT" '
  ($review[0].entries // [] | map(.id) | unique) as $active
  | to_entries[]
  | select(.key as $id | $active | index($id))
' "$DECISIONS")

echo "apply-review-decisions: approved=$APPROVED rejected=$REJECTED deferred=$DEFERRED errors=$ERRORS" >&2

# Emit accumulated fact lines to stdout for the receipt
printf '%s' "$FACT_LINES"

[ "$ERRORS" -eq 0 ] || exit 1
