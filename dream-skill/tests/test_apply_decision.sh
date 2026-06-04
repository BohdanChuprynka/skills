#!/usr/bin/env bash
# Test: apply-decision.sh maps reconciliation-decision JSON → correct vault-writer/queue calls
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLY="$SCRIPT_DIR/../scripts/apply-decision.sh"
WRITER="$SCRIPT_DIR/../scripts/vault-writer.sh"
QUEUE="$SCRIPT_DIR/../scripts/queue.sh"

[ -x "$APPLY" ] || { echo "FAIL: apply-decision.sh missing or not executable"; exit 1; }

# Setup mock vault in tmp
VAULT=$(mktemp -d "/tmp/dream-apply-test-XXXXXX")
trap 'rm -rf "$VAULT"' EXIT

mkdir -p "$VAULT/wiki"
UNDO_LOG="$VAULT/undo.jsonl"
DECISION_FILE="$VAULT/decision.json"

fail() { echo "FAIL: $*"; exit 1; }

# --- Test 1: new (high confidence) → append call, no queue entry ---

cat > "$VAULT/wiki/skills.md" <<'EOF'
# Skills

## Certifications

- holds CKAD cert
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "Passed AWS Solutions Architect exam 2026-05",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Absent fact, high confidence."
}
EOF

FACT1=$("$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG")

grep -q "Passed AWS Solutions Architect" "$VAULT/wiki/skills.md" \
  || fail "new: content not appended"
[ ! -f "${DREAM_QUEUE_FILE:-}" ] || ! grep -q "AWS Solutions Architect" "${DREAM_QUEUE_FILE:-/dev/null}" \
  || fail "new high-confidence: should not be queued"
# Assert run-summary fact: target is a flat string, action=new, review_status=written
[ "$(printf '%s' "$FACT1" | jq -r 'select(type=="object") | .target | type')" = "string" ] \
  || fail "new: emitted fact .target is not a string (got: $FACT1)"
[ "$(printf '%s' "$FACT1" | jq -r '.action')" = "new" ] \
  || fail "new: emitted fact .action is not 'new'"
[ "$(printf '%s' "$FACT1" | jq -r '.review_status')" = "written" ] \
  || fail "new: emitted fact .review_status is not 'written'"
echo "PASS: new action → appends content, no queue entry, emits run-summary fact (flattened target, action=new, review_status=written)"

# --- Test 2: duplicate → no write ---

PAGE_BEFORE=$(cat "$VAULT/wiki/skills.md")

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "duplicate",
  "mode": "none",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Already present."
}
EOF

FACT2=$("$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG")

PAGE_AFTER=$(cat "$VAULT/wiki/skills.md")
[ "$PAGE_BEFORE" = "$PAGE_AFTER" ] || fail "duplicate: page was modified when it should not be"
# Assert run-summary fact: target is a flat string, action=duplicate, review_status=skipped
[ "$(printf '%s' "$FACT2" | jq -r 'select(type=="object") | .target | type')" = "string" ] \
  || fail "duplicate: emitted fact .target is not a string (got: $FACT2)"
[ "$(printf '%s' "$FACT2" | jq -r '.action')" = "duplicate" ] \
  || fail "duplicate: emitted fact .action is not 'duplicate'"
[ "$(printf '%s' "$FACT2" | jq -r '.review_status')" = "skipped" ] \
  || fail "duplicate: emitted fact .review_status is not 'skipped'"
echo "PASS: duplicate action → no write, emits run-summary fact (flattened target, action=duplicate, review_status=skipped)"

# --- Test 3: supersede → replace call with old_content ---

cat > "$VAULT/wiki/bio.md" <<'EOF'
# Bio

## Bio

- lives in Berlin
- originally from Kyiv
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "supersede",
  "mode": "replace",
  "target": { "vault": "me", "page": "wiki/bio.md", "section": "Bio" },
  "old_content": "lives in Berlin",
  "content": "lives in Munich (moved 2026-06)",
  "candidate_confidence": "high",
  "needs_review": true,
  "rationale": "Newer source_date wins."
}
EOF

QUEUE_FILE=$(mktemp "/tmp/dream-queue-XXXXXX.md")
export DREAM_QUEUE_FILE="$QUEUE_FILE"

FACT3=$("$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG")

grep -q "lives in Munich" "$VAULT/wiki/bio.md" \
  || fail "supersede: new content not present"
grep -q "lives in Berlin" "$VAULT/wiki/bio.md" \
  && fail "supersede: old content still present"
grep -q "lives in Munich" "$QUEUE_FILE" \
  || fail "supersede: not enqueued for review"
grep -qi "destructive" "$QUEUE_FILE" \
  || fail "supersede: queue bucket must be 'destructive'"
# Assert run-summary fact: target is a flat string, action=supersede, review_status=written
[ "$(printf '%s' "$FACT3" | jq -r 'select(type=="object") | .target | type')" = "string" ] \
  || fail "supersede: emitted fact .target is not a string (got: $FACT3)"
[ "$(printf '%s' "$FACT3" | jq -r '.action')" = "supersede" ] \
  || fail "supersede: emitted fact .action is not 'supersede'"
[ "$(printf '%s' "$FACT3" | jq -r '.review_status')" = "written" ] \
  || fail "supersede: emitted fact .review_status is not 'written'"
echo "PASS: supersede action → replace call + queue entry (destructive bucket), emits run-summary fact (flattened target, action=supersede, review_status=written)"

# --- Test 4: contradict → stale call + queue entry, new content NOT written ---

cat > "$VAULT/wiki/skills.md" <<'EOF'
# Skills

## Languages

- primary language is Python (since 2023)
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "contradict",
  "mode": "stale",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Languages" },
  "old_content": "primary language is Python (since 2023)",
  "content": "primary language is TypeScript",
  "candidate_confidence": "high",
  "needs_review": true,
  "rationale": "Winner unclear."
}
EOF

FACTS4=$("$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG")

grep -q "~~primary language is Python" "$VAULT/wiki/skills.md" \
  || fail "contradict: old line not struck through"
grep -q "primary language is TypeScript" "$VAULT/wiki/skills.md" \
  && fail "contradict: new content must NOT be written to vault"
grep -q "primary language is TypeScript" "$QUEUE_FILE" \
  || fail "contradict: new content not enqueued for review"
grep -qi "destructive" "$QUEUE_FILE" \
  || fail "contradict: queue bucket must be 'destructive'"
# Assert TWO run-summary facts emitted: written-old (action=contradict, review_status=written)
# and queued-new (action=contradict, review_status=queued)
FACT4_WRITTEN=$(printf '%s' "$FACTS4" | grep '"review_status":"written"' | head -1)
FACT4_QUEUED=$(printf '%s' "$FACTS4"  | grep '"review_status":"queued"'  | head -1)
[ -n "$FACT4_WRITTEN" ] \
  || fail "contradict: no written-old run-summary fact emitted (got: $FACTS4)"
[ -n "$FACT4_QUEUED" ] \
  || fail "contradict: no queued-new run-summary fact emitted (got: $FACTS4)"
[ "$(printf '%s' "$FACT4_WRITTEN" | jq -r '.target | type')" = "string" ] \
  || fail "contradict: written-old fact .target is not a string"
[ "$(printf '%s' "$FACT4_QUEUED"  | jq -r '.target | type')" = "string" ] \
  || fail "contradict: queued-new fact .target is not a string"
[ "$(printf '%s' "$FACT4_QUEUED"  | jq -r '.action')" = "contradict" ] \
  || fail "contradict: queued-new fact .action is not 'contradict'"
echo "PASS: contradict action → stale call + queue entry (destructive bucket), new content not in vault, emits written-old + queued-new run-summary facts (both with flattened target)"

# --- Test 5: new with needs_review:true → queue only, NOT written to vault ---

cat > "$VAULT/wiki/goals.md" <<'EOF'
# Goals

## Goals

- become a strong ML engineer
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/goals.md", "section": "Goals" },
  "content": "might pivot to product management",
  "candidate_confidence": "low",
  "needs_review": true,
  "rationale": "Low confidence, brainstormed fact."
}
EOF

FACT5=$("$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG")

grep -q "might pivot to product management" "$VAULT/wiki/goals.md" \
  && fail "new needs_review:true: should NOT auto-write to vault"
grep -q "pivot to product management" "$QUEUE_FILE" \
  || fail "new needs_review:true: should be enqueued"
grep -qi "brainstormed" "$QUEUE_FILE" \
  || fail "new low-confidence: queue bucket must be 'brainstormed'"
# Assert run-summary fact: target is a flat string, action=new, review_status=queued
[ "$(printf '%s' "$FACT5" | jq -r 'select(type=="object") | .target | type')" = "string" ] \
  || fail "new needs_review: emitted fact .target is not a string (got: $FACT5)"
[ "$(printf '%s' "$FACT5" | jq -r '.action')" = "new" ] \
  || fail "new needs_review: emitted fact .action is not 'new'"
[ "$(printf '%s' "$FACT5" | jq -r '.review_status')" = "queued" ] \
  || fail "new needs_review: emitted fact .review_status is not 'queued'"
echo "PASS: new needs_review:true (low confidence) → not written, queued in brainstormed bucket, emits run-summary fact (flattened target, action=new, review_status=queued)"

rm -f "$QUEUE_FILE"

# --- Test 6: --dry-run new → vault page byte-identical, queue file untouched ---

cat > "$VAULT/wiki/skills.md" <<'EOF'
# Skills

## Certifications

- holds CKAD cert
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "dry-run new fact",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Test dry-run new."
}
EOF

DRYRUN_QUEUE=$(mktemp "/tmp/dream-dryrun-queue-XXXXXX.md")
export DREAM_QUEUE_FILE="$DRYRUN_QUEUE"

BEFORE_PAGE_HASH=$(shasum -a 256 "$VAULT/wiki/skills.md" | awk '{print $1}')
BEFORE_QUEUE_LINES=$(wc -l < "$DRYRUN_QUEUE")

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG" --dry-run

AFTER_PAGE_HASH=$(shasum -a 256 "$VAULT/wiki/skills.md" | awk '{print $1}')
[ "$BEFORE_PAGE_HASH" = "$AFTER_PAGE_HASH" ] \
  || fail "--dry-run new: vault page was modified (hashes differ)"
AFTER_QUEUE_LINES=$(wc -l < "$DRYRUN_QUEUE")
[ "$BEFORE_QUEUE_LINES" -eq "$AFTER_QUEUE_LINES" ] \
  || fail "--dry-run new: queue file was written"
echo "PASS: --dry-run new → vault page byte-identical, queue untouched"

rm -f "$DRYRUN_QUEUE"

# --- Test 7: --dry-run supersede → vault page byte-identical, queue file untouched ---

cat > "$VAULT/wiki/bio.md" <<'EOF'
# Bio

## Bio

- lives in Berlin
- originally from Kyiv
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "supersede",
  "mode": "replace",
  "target": { "vault": "me", "page": "wiki/bio.md", "section": "Bio" },
  "old_content": "lives in Berlin",
  "content": "lives in Munich (moved 2026-06)",
  "candidate_confidence": "high",
  "needs_review": true,
  "rationale": "Test dry-run supersede."
}
EOF

DRYRUN_QUEUE2=$(mktemp "/tmp/dream-dryrun-queue2-XXXXXX.md")
export DREAM_QUEUE_FILE="$DRYRUN_QUEUE2"

BEFORE_PAGE_HASH=$(shasum -a 256 "$VAULT/wiki/bio.md" | awk '{print $1}')
BEFORE_QUEUE_LINES=$(wc -l < "$DRYRUN_QUEUE2")

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG" --dry-run

AFTER_PAGE_HASH=$(shasum -a 256 "$VAULT/wiki/bio.md" | awk '{print $1}')
[ "$BEFORE_PAGE_HASH" = "$AFTER_PAGE_HASH" ] \
  || fail "--dry-run supersede: vault page was modified (hashes differ)"
AFTER_QUEUE_LINES=$(wc -l < "$DRYRUN_QUEUE2")
[ "$BEFORE_QUEUE_LINES" -eq "$AFTER_QUEUE_LINES" ] \
  || fail "--dry-run supersede: queue file was written"
echo "PASS: --dry-run supersede → vault page byte-identical, queue untouched"

rm -f "$DRYRUN_QUEUE2"

# --- Test 8: new + medium confidence + needs_review:true → uncertain bucket (not brainstormed) ---

cat > "$VAULT/wiki/career.md" <<'EOF'
# Career

## Goals

- become a strong ML engineer
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/career.md", "section": "Goals" },
  "content": "considering a switch to product management",
  "candidate_confidence": "medium",
  "needs_review": true,
  "rationale": "Medium confidence, uncertain fact."
}
EOF

QUEUE_8=$(mktemp "/tmp/dream-queue-test8-XXXXXX.md")
export DREAM_QUEUE_FILE="$QUEUE_8"

FACT8=$("$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG")

grep -q "considering a switch" "$VAULT/wiki/career.md" \
  && fail "test 8: medium-confidence needs_review: must NOT auto-write to vault"
grep -q "considering a switch" "$QUEUE_8" \
  || fail "test 8: medium-confidence needs_review: must be queued"
grep -qi "uncertain" "$QUEUE_8" \
  || fail "test 8: medium-confidence needs_review: queue bucket must be 'uncertain'"
grep -qi "brainstormed" "$QUEUE_8" \
  && fail "test 8: medium-confidence needs_review: must NOT be in brainstormed bucket"
[ "$(printf '%s' "$FACT8" | jq -r '.review_status')" = "queued" ] \
  || fail "test 8: run-summary fact review_status must be 'queued'"
[ "$(printf '%s' "$FACT8" | jq -r '.queue_bucket')" = "uncertain" ] \
  || fail "test 8: run-summary fact queue_bucket must be 'uncertain'"
rm -f "$QUEUE_8"
echo "PASS: new medium-confidence needs_review:true → uncertain bucket (not brainstormed)"

# --- Test 9: unknown action → non-zero exit + "unknown action" in stderr ---

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "frobble",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "some content",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Test unknown action."
}
EOF

RC9=0
ERR9=$(DREAM_QUEUE_FILE="/dev/null" \
  "$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG" 2>&1) || RC9=$?
[ "$RC9" -ne 0 ] || fail "test 9: unknown action should exit non-zero"
printf '%s' "$ERR9" | grep -qi "unknown action\|frobble" \
  || fail "test 9: stderr missing 'unknown action' or action name (got: $ERR9)"
echo "PASS: unknown action → non-zero exit + 'unknown action' in stderr"

# --- Test 10: null .target.page in decision → non-zero exit, no null.md created ---

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": null, "section": "Certifications" },
  "content": "should not reach vault",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Test null page field."
}
EOF

RC10=0
ERR10=$(DREAM_QUEUE_FILE="/dev/null" \
  "$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG" 2>&1) || RC10=$?
[ "$RC10" -ne 0 ] || fail "test 10: null .target.page should exit non-zero"
[ ! -f "$VAULT/null.md" ] || fail "test 10: null .target.page created null.md in vault"
printf '%s' "$ERR10" | grep -qi "page\|missing\|null" \
  || fail "test 10: stderr should mention missing page (got: $ERR10)"
echo "PASS: null .target.page → non-zero exit, no null.md created"

echo "All apply-decision.sh tests passed."
