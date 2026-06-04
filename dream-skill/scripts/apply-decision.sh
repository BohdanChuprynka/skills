#!/usr/bin/env bash
# dream-skill apply-decision.
# Reads a reconciliation-decision JSON file and dispatches to vault-writer.sh
# and/or queue.sh according to the action→mode→vault-writer/queue mapping.
#
# This is the SOLE owner of the action→mode→vault-writer/queue mapping.
# Plan 4's orchestrator calls this as a black box.
#
# Action dispatch table:
#   new        → vault-writer --mode append (unless needs_review:true → queue only)
#   duplicate  → skip (no write, no queue)
#   supersede  → vault-writer --mode replace + queue (destructive bucket)
#   contradict → vault-writer --mode stale (old line struck through) + queue (destructive)
#                new content is NOT written to vault for contradict — queued only
#
# Bucket mapping (derived from candidate_confidence, never hardcoded by action):
#   supersede/contradict → destructive
#   new needs_review:true + confidence:low    → brainstormed
#   new needs_review:true + confidence:medium → uncertain
#
# Usage:
#   apply-decision.sh \
#     --vault <vault-root> \
#     --decision <path-to-decision.json> \
#     --undo-log <path-to-undo.jsonl>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="$SCRIPT_DIR/vault-writer.sh"
QUEUE_SH="$SCRIPT_DIR/queue.sh"

VAULT=""
DECISION=""
UNDO_LOG=""

die() { echo "apply-decision: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vault)    VAULT="$2";    shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    --undo-log) UNDO_LOG="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$VAULT" ]    || die "missing --vault"
[ -n "$DECISION" ] || die "missing --decision"
[ -n "$UNDO_LOG" ] || die "missing --undo-log"
[ -d "$VAULT" ]    || die "vault dir not found: $VAULT"
[ -f "$DECISION" ] || die "decision file not found: $DECISION"
[ -x "$WRITER" ]   || die "vault-writer.sh not found or not executable: $WRITER"
[ -x "$QUEUE_SH" ] || die "queue.sh not found or not executable: $QUEUE_SH"

# --- Parse decision JSON ---
action=$(jq -r '.action'               "$DECISION")
page=$(jq -r '.target.page'            "$DECISION")
section=$(jq -r '.target.section'      "$DECISION")
content=$(jq -r '.content // ""'       "$DECISION")
old_content=$(jq -r '.old_content // ""' "$DECISION")
candidate_confidence=$(jq -r '.candidate_confidence' "$DECISION")
needs_review=$(jq -r '.needs_review'   "$DECISION")
rationale=$(jq -r '.rationale // ""'   "$DECISION")

[ -n "$action" ]  || die "decision missing .action"
[ -n "$page" ]    || die "decision missing .target.page"
[ -n "$section" ] || die "decision missing .target.section"

# Derive queue bucket from candidate_confidence for destructive actions.
# For new+needs_review, bucket depends on confidence level.
_bucket_for_confidence() {
  # $1 = candidate_confidence
  case "$1" in
    low)    echo "brainstormed" ;;
    medium) echo "uncertain" ;;
    *)      echo "destructive" ;;  # high or unknown → treated as destructive for supersede/contradict
  esac
}

# --- Dispatch ---
case "$action" in

  new)
    if [ "$needs_review" = "true" ]; then
      # Low/medium confidence fact: queue only, do NOT write to vault
      bucket=$(_bucket_for_confidence "$candidate_confidence")
      "$QUEUE_SH" append \
        --bucket "$bucket" \
        --title  "$content" \
        --evidence "$rationale" \
        --confidence "$candidate_confidence" \
        --target "${VAULT}/${page}#${section}"
    else
      # High-confidence new fact: append directly to vault
      "$WRITER" \
        --vault    "$VAULT" \
        --page     "$page" \
        --section  "$section" \
        --content  "$content" \
        --mode     append \
        --undo-log "$UNDO_LOG" \
        --no-index-update
    fi
    ;;

  duplicate)
    # Already present — skip entirely (no write, no queue)
    ;;

  supersede)
    # Destructive: replace old line with new content, then queue for review
    "$WRITER" \
      --vault       "$VAULT" \
      --page        "$page" \
      --section     "$section" \
      --content     "$content" \
      --mode        replace \
      --old-content "$old_content" \
      --undo-log    "$UNDO_LOG" \
      --no-index-update
    "$QUEUE_SH" append \
      --bucket destructive \
      --title  "$content" \
      --evidence "$rationale" \
      --confidence "$candidate_confidence" \
      --target "${VAULT}/${page}#${section}"
    ;;

  contradict)
    # Mark old line stale (struck through); queue the NEW content for human review.
    # vault-writer --mode stale requires --content even though it only modifies the
    # old line — we pass old_content as a harmless dummy to satisfy the interface.
    "$WRITER" \
      --vault       "$VAULT" \
      --page        "$page" \
      --section     "$section" \
      --content     "$old_content" \
      --mode        stale \
      --old-content "$old_content" \
      --undo-log    "$UNDO_LOG" \
      --no-index-update
    # Queue the new contradicting content for human review (do NOT write to vault)
    "$QUEUE_SH" append \
      --bucket destructive \
      --title  "$content" \
      --evidence "$rationale" \
      --confidence "$candidate_confidence" \
      --target "${VAULT}/${page}#${section}"
    ;;

  *)
    die "unknown action: $action"
    ;;
esac
