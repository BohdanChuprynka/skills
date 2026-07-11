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
#   any needs_review:true decision → durable queue + sidecar only; no vault mutation
#   supersede/contradict after approval → exact-line replacement
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
#     --undo-log <path-to-undo.jsonl> \
#     [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="$SCRIPT_DIR/vault-writer.sh"
QUEUE_SH="$SCRIPT_DIR/queue.sh"

VAULT=""
DECISION=""
UNDO_LOG=""
DRY_RUN=0
CANDIDATE_ID=""

die() { echo "apply-decision: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vault)        VAULT="$2";        shift 2 ;;
    --decision)     DECISION="$2";     shift 2 ;;
    --undo-log)     UNDO_LOG="$2";     shift 2 ;;
    --dry-run)      DRY_RUN=1;         shift ;;
    --candidate-id) CANDIDATE_ID="$2"; shift 2 ;;
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
action=$(jq -r '.action // empty'               "$DECISION")
vault_name=$(jq -r '.target.vault // ""'         "$DECISION")
page=$(jq -r '.target.page // empty'             "$DECISION")
section=$(jq -r '.target.section // empty'       "$DECISION")
content=$(jq -r '.content // ""'                 "$DECISION")
old_content=$(jq -r '.old_content // ""'         "$DECISION")
candidate_confidence=$(jq -r '.candidate_confidence // empty' "$DECISION")
needs_review=$(jq -r '.needs_review // empty'    "$DECISION")
rationale=$(jq -r '.rationale // ""'             "$DECISION")

[ -n "$action" ]  || die "decision missing .action"
[ -n "$page" ]    || die "decision missing .target.page"
[ -n "$section" ] || die "decision missing .target.section"

# Flat target string for run-summary facts: "<vault_name>/<page>"
# This is the single place that owns the object→string flatten (FIX 1).
_target_str="${vault_name}/${page}"

# Emit one run-summary fact line (JSON) to stdout.
# $1=content $2=old_content $3=action $4=review_status $5=queue_bucket
_emit_fact() {
  local _c="$1" _old="$2" _act="$3" _rs="$4" _qb="$5"
  printf '%s\n' "$(jq -cn \
    --arg content   "$_c" \
    --arg old_content "$_old" \
    --arg target    "$_target_str" \
    --arg action    "$_act" \
    --arg review_status "$_rs" \
    --arg queue_bucket  "$_qb" \
    --arg confidence    "$candidate_confidence" \
    '{content:$content, old_content:$old_content, target:$target, action:$action, review_status:$review_status, queue_bucket:$queue_bucket, confidence:$confidence}')"
}

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

# Build optional --dry-run flag to pass down to sub-tools
_dry_flag() { [ "$DRY_RUN" = "1" ] && echo "--dry-run" || true; }

# Write sidecar JSON for web review UI (only when --candidate-id provided, not dry-run)
_write_sidecar() {
  [ -n "$CANDIDATE_ID" ] || return 0
  [ "$DRY_RUN" = "1" ]   && return 0
  local sdir="${DREAM_HOME:-$HOME/.claude/dream-skill}/queue/sidecars"
  mkdir -p "$sdir"
  chmod 700 "$sdir" 2>/dev/null || true
  local target_display="${VAULT}/${page}#${section}"
  local tmp="$sdir/.${CANDIDATE_ID}.tmp.$$"
  jq --arg cid "$CANDIDATE_ID" --arg vroot "$VAULT" \
     --arg title "$content" --arg target_display "$target_display" \
     '. + {candidate_id: $cid, vault_root: $vroot, title: $title, target_display: $target_display}' \
     "$DECISION" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$sdir/$CANDIDATE_ID.json"
}

_queue_for_review() {
  local bucket="$1"
  if [ "$DRY_RUN" = "1" ]; then
    echo "apply-decision [dry-run]: would queue action=$action bucket=$bucket title='$content' target=${VAULT}/${page}#${section}"
  else
    _write_sidecar
    "$QUEUE_SH" append \
      --bucket "$bucket" \
      --title "$content" \
      --evidence "$rationale" \
      --confidence "$candidate_confidence" \
      --id "${CANDIDATE_ID:-}" \
      --target "${VAULT}/${page}#${section}"
  fi
  _emit_fact "$content" "$old_content" "$action" "queued" "$bucket"
}

# Review is a real write gate. No action carrying needs_review=true may mutate a
# vault before the user approves its sidecar.
if [ "$needs_review" = "true" ] && [ "$action" != "duplicate" ]; then
  case "$action" in
    supersede|contradict) review_bucket="destructive" ;;
    new) review_bucket=$(_bucket_for_confidence "$candidate_confidence") ;;
    *) die "unknown review action: $action" ;;
  esac
  _queue_for_review "$review_bucket"
  exit 0
fi

# --- Dispatch ---
case "$action" in

  new)
    "$WRITER" \
      --vault    "$VAULT" \
      --page     "$page" \
      --section  "$section" \
      --content  "$content" \
      --mode     append \
      --undo-log "$UNDO_LOG" \
      --no-index-update \
      $(_dry_flag)
    _emit_fact "$content" "" "new" "written" ""
    ;;

  duplicate)
    # Already present — skip entirely (no write, no queue)
    _emit_fact "$content" "" "duplicate" "skipped" ""
    ;;

  supersede)
    # This branch is reachable only after review approval forced needs_review=false.
    "$WRITER" \
      --vault       "$VAULT" \
      --page        "$page" \
      --section     "$section" \
      --content     "$content" \
      --mode        replace \
      --old-content "$old_content" \
      --undo-log    "$UNDO_LOG" \
      --no-index-update \
      $(_dry_flag)
    _emit_fact "$content" "$old_content" "supersede" "written" ""
    ;;

  contradict)
    # Approval resolves the ambiguity in favor of the proposed content. Undo
    # preserves the previous exact line, so the page stays concise.
    "$WRITER" \
      --vault       "$VAULT" \
      --page        "$page" \
      --section     "$section" \
      --content     "$content" \
      --mode        replace \
      --old-content "$old_content" \
      --undo-log    "$UNDO_LOG" \
      --no-index-update \
      $(_dry_flag)
    _emit_fact "$content" "$old_content" "contradict" "written" ""
    ;;

  *)
    die "unknown action: $action"
    ;;
esac
