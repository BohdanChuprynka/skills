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

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "Passed AWS Solutions Architect" "$VAULT/wiki/skills.md" \
  || fail "new: content not appended"
[ ! -f "${DREAM_QUEUE_FILE:-}" ] || ! grep -q "AWS Solutions Architect" "${DREAM_QUEUE_FILE:-/dev/null}" \
  || fail "new high-confidence: should not be queued"
echo "PASS: new action → appends content, no queue entry"

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

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

PAGE_AFTER=$(cat "$VAULT/wiki/skills.md")
[ "$PAGE_BEFORE" = "$PAGE_AFTER" ] || fail "duplicate: page was modified when it should not be"
echo "PASS: duplicate action → no write"

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

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "lives in Munich" "$VAULT/wiki/bio.md" \
  || fail "supersede: new content not present"
grep -q "lives in Berlin" "$VAULT/wiki/bio.md" \
  && fail "supersede: old content still present"
grep -q "lives in Munich" "$QUEUE_FILE" \
  || fail "supersede: not enqueued for review"
grep -qi "destructive" "$QUEUE_FILE" \
  || fail "supersede: queue bucket must be 'destructive'"
echo "PASS: supersede action → replace call + queue entry (destructive bucket)"

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

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "~~primary language is Python" "$VAULT/wiki/skills.md" \
  || fail "contradict: old line not struck through"
grep -q "primary language is TypeScript" "$VAULT/wiki/skills.md" \
  && fail "contradict: new content must NOT be written to vault"
grep -q "primary language is TypeScript" "$QUEUE_FILE" \
  || fail "contradict: new content not enqueued for review"
grep -qi "destructive" "$QUEUE_FILE" \
  || fail "contradict: queue bucket must be 'destructive'"
echo "PASS: contradict action → stale call + queue entry (destructive bucket), new content not in vault"

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

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "might pivot to product management" "$VAULT/wiki/goals.md" \
  && fail "new needs_review:true: should NOT auto-write to vault"
grep -q "pivot to product management" "$QUEUE_FILE" \
  || fail "new needs_review:true: should be enqueued"
grep -qi "brainstormed" "$QUEUE_FILE" \
  || fail "new low-confidence: queue bucket must be 'brainstormed'"
echo "PASS: new needs_review:true (low confidence) → not written, queued in brainstormed bucket"

rm -f "$QUEUE_FILE"
