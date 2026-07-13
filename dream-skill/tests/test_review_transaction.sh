#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export DREAM_HOME="$TMP/state"
export DREAM_QUEUE_FILE="$DREAM_HOME/queue/pending.md"
VAULT="$TMP/vault"
PAGE="$VAULT/wiki/page.md"
UNDO="$DREAM_HOME/undo/test.jsonl"
SCOPED_UNDO="$DREAM_HOME/undo/run-week-1.jsonl"
mkdir -p "$VAULT/wiki" "$DREAM_HOME/queue/sidecars"
printf '# Page\n\n## Facts\n\n- Old fact\n' > "$PAGE"

decision() {
  local path="$1" action="$2" old="$3" new="$4"
  jq -n \
    --arg action "$action" --arg old "$old" --arg new "$new" \
    '{action:$action, mode:"replace", target:{vault:"test",page:"wiki/page.md",section:"Facts"}, old_content:$old, content:$new, candidate_confidence:"high", needs_review:true, rationale:"user correction", evidence:"exact user words", source_chat:"/private/chat.jsonl", source_event:7, candidate_type:"preference", memory_tier:"current", source_role:"user", source_date:"2026-04-01", historical_review:true, quality_review_sample:true, run_id:"run-week-1", run_window:{start:"2026-04-01",end:"2026-04-08"}, model_profile:{map:"luna",route:"luna",reconcile:"luna"}}' \
    > "$path"
}

build_review() {
  "$SCRIPTS/build-review-queue.py" \
    --pending-md "$DREAM_QUEUE_FILE" \
    --sidecars-dir "$DREAM_HOME/queue/sidecars" \
    --output "$DREAM_HOME/queue/review-input.json" \
    --existing-decisions "$DREAM_HOME/queue/review-decisions.json" >/dev/null
}

# Reject: staging must not mutate; rejection removes only queue state.
decision "$TMP/reject.json" supersede "- Old fact" "- Rejected fact"
before=$(shasum -a 256 "$PAGE" | awk '{print $1}')
"$SCRIPTS/apply-decision.sh" --vault "$VAULT" --decision "$TMP/reject.json" \
  --undo-log "$UNDO" --candidate-id c-reject >/dev/null
after=$(shasum -a 256 "$PAGE" | awk '{print $1}')
[ "$before" = "$after" ] || { echo "reject staging mutated page" >&2; exit 1; }
jq -e '.target_display | endswith("/wiki/page.md#Facts")' "$DREAM_HOME/queue/sidecars/c-reject.json" >/dev/null
  jq -e '.source_chat == "/private/chat.jsonl" and .source_event == 7 and .evidence == "exact user words" and .rationale == "user correction"' "$DREAM_HOME/queue/sidecars/c-reject.json" >/dev/null
build_review
jq -e '.entries[0].candidate_type == "preference" and .entries[0].memory_tier == "current" and .entries[0].source_role == "user" and .entries[0].source_date == "2026-04-01" and .entries[0].source_chat == "/private/chat.jsonl" and .entries[0].source_event == 7 and .entries[0].source_evidence == "exact user words" and .entries[0].context == "exact user words" and .entries[0].reconciliation_rationale == "user correction" and .entries[0].historical_review == true and .entries[0].quality_review_sample == true and .entries[0].run_id == "run-week-1" and .entries[0].run_window.start == "2026-04-01" and .entries[0].model_profile.map == "luna"' "$DREAM_HOME/queue/review-input.json" >/dev/null
printf '{"c-reject":"reject"}\n' > "$DREAM_HOME/queue/review-decisions.json"
"$SCRIPTS/apply-review-decisions.sh" --decisions "$DREAM_HOME/queue/review-decisions.json" \
  --review-input "$DREAM_HOME/queue/review-input.json" \
  --sidecars-dir "$DREAM_HOME/queue/sidecars" --undo-log "$UNDO" >/dev/null
[ ! -e "$DREAM_HOME/queue/sidecars/c-reject.json" ]
! rg -q '^### - Rejected fact$' "$DREAM_QUEUE_FILE"
[ "$before" = "$(shasum -a 256 "$PAGE" | awk '{print $1}')" ]

# Approve: exact replacement occurs once, then queue and sidecar disappear.
decision "$TMP/approve.json" supersede "- Old fact" "- Approved fact"
"$SCRIPTS/apply-decision.sh" --vault "$VAULT" --decision "$TMP/approve.json" \
  --undo-log "$UNDO" --candidate-id c-approve >/dev/null
build_review
printf '{"c-approve":"approve"}\n' > "$DREAM_HOME/queue/review-decisions.json"
"$SCRIPTS/apply-review-decisions.sh" --decisions "$DREAM_HOME/queue/review-decisions.json" \
  --review-input "$DREAM_HOME/queue/review-input.json" \
  --sidecars-dir "$DREAM_HOME/queue/sidecars" --undo-log "$UNDO" >/dev/null
rg -Fxq -- '- Approved fact' "$PAGE"
! rg -Fxq -- '- Old fact' "$PAGE"
[ ! -e "$DREAM_HOME/queue/sidecars/c-approve.json" ]
! rg -q '^### - Approved fact$' "$DREAM_QUEUE_FILE"
[ "$(wc -l < "$SCOPED_UNDO" | tr -d ' ')" = "1" ]

# A no-op retry must not add an undo entry.
"$SCRIPTS/vault-writer.sh" --vault "$VAULT" --page wiki/page.md --section Facts \
  --content 'Approved fact' --mode append --undo-log "$SCOPED_UNDO" --no-index-update
[ "$(wc -l < "$SCOPED_UNDO" | tr -d ' ')" = "1" ]

# Failed approval retains both durable queue state and its sidecar for retry.
decision "$TMP/fail.json" supersede "- Missing fact" "- New fact"
"$SCRIPTS/apply-decision.sh" --vault "$VAULT" --decision "$TMP/fail.json" \
  --undo-log "$UNDO" --candidate-id c-fail >/dev/null
build_review
printf '{"c-fail":"approve"}\n' > "$DREAM_HOME/queue/review-decisions.json"
if "$SCRIPTS/apply-review-decisions.sh" --decisions "$DREAM_HOME/queue/review-decisions.json" \
  --review-input "$DREAM_HOME/queue/review-input.json" \
  --sidecars-dir "$DREAM_HOME/queue/sidecars" --undo-log "$UNDO" >/dev/null 2>&1; then
  echo "failed approval unexpectedly succeeded" >&2
  exit 1
fi
[ -f "$DREAM_HOME/queue/sidecars/c-fail.json" ]
rg -q '^### - New fact$' "$DREAM_QUEUE_FILE"

# Legacy queue entries without sidecars are excluded instead of becoming
# unapplyable review cards.
"$SCRIPTS/queue.sh" append --bucket uncertain --title 'Legacy orphan' \
  --evidence 'legacy' --confidence medium --id c-orphan --target "$VAULT/wiki/page.md#Facts"
build_review
[ "$(jq '[.entries[] | select(.id == "c-orphan")] | length' "$DREAM_HOME/queue/review-input.json")" = "0" ]

echo "test_review_transaction: ok"
