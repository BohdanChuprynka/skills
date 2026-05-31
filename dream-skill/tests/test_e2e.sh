#!/usr/bin/env bash
# End-to-end pipeline test: trigger → preprocess → vault-writer + queue → undo
# Simulates what SKILL.md auto-mode would do.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
FIXTURES="$SCRIPT_DIR/fixtures"

# Workspace
WORK=$(mktemp -d "/tmp/dream-e2e-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

VAULT="$WORK/vault"
QUEUE_FILE="$WORK/pending.md"
UNDO_LOG="$WORK/undo.jsonl"
TRIGGER_LOG="$WORK/trigger.log"

mkdir -p "$VAULT/wiki"
cat > "$VAULT/wiki/index.md" <<'EOF'
# Wiki Index
EOF
cat > "$VAULT/wiki/me.md" <<'EOF'
# Me

## Current focus

- existing item
EOF

fail() { echo "FAIL: $*"; exit 1; }

# === Stage 1: trigger fires on 15-msg fixture (stub dispatch) ===
export DREAM_DISPATCH_STUB=1
export DREAM_LOG="$TRIGGER_LOG"
export DREAM_LOCK_DIR="$WORK/locks"
export DREAM_REPORTS_DIR="$WORK/reports"   # never touch the real vault
mkdir -p "$DREAM_LOCK_DIR"
CLAUDE_TRANSCRIPT_PATH="$FIXTURES/transcript-15msg.jsonl" "$SCRIPTS/trigger.sh"
grep -q "DISPATCH" "$TRIGGER_LOG" || fail "trigger did not dispatch on 15-msg"
echo "PASS: stage 1 — trigger dispatched"

# === Stage 2: preprocess noisy transcript ===
CLEAN=$("$SCRIPTS/preprocess.sh" "$FIXTURES/transcript-noisy.jsonl")
[ -n "$CLEAN" ] || fail "preprocess produced empty output"
echo "$CLEAN" | grep -q "Schedule 9am block" || fail "preprocess missing expected content"
echo "$CLEAN" | grep -q "BIG_MCP_DATA_BLOB" && fail "preprocess leaked tool_result"
echo "PASS: stage 2 — preprocess stripped + kept correct content"

# === Stage 3: simulate SKILL.md auto-mode decisions ===
# Bucket A (HIGH CONFIDENCE) → vault-writer
"$SCRIPTS/vault-writer.sh" \
  --vault "$VAULT" \
  --page "wiki/me.md" \
  --section "Current focus" \
  --content "Project X 9am block (from session)" \
  --undo-log "$UNDO_LOG" \
  --index-label "Me" \
  --index-desc "Personal page"

grep -q "Project X 9am block" "$VAULT/wiki/me.md" || fail "high-confidence fact not written"
grep -q "existing item" "$VAULT/wiki/me.md" || fail "existing content lost"
grep -q "me.md" "$VAULT/wiki/index.md" || fail "index not updated"
echo "PASS: stage 3a — high-confidence fact written to vault + index"

# Bucket D (DESTRUCTIVE) → queue
export DREAM_QUEUE_FILE="$QUEUE_FILE"
"$SCRIPTS/queue.sh" append \
  --bucket destructive \
  --title "Replace old item" \
  --evidence "actually it's a new item" \
  --confidence medium \
  --target "wiki/me.md"

grep -q "Replace old item" "$QUEUE_FILE" || fail "destructive entry not queued"
echo "PASS: stage 3b — destructive fact queued"

# Bucket E (BRAINSTORMED) → queue
"$SCRIPTS/queue.sh" append \
  --bucket brainstormed \
  --title "Maybe try new framework" \
  --evidence "thinking about it" \
  --confidence low \
  --target "wiki/me.md"

grep -q "Maybe try new framework" "$QUEUE_FILE" || fail "brainstormed entry not queued"
echo "PASS: stage 3c — brainstormed fact queued"

# === Stage 4: undo reverses high-confidence writes ===
"$SCRIPTS/apply-undo.sh" "$UNDO_LOG" > /dev/null

grep -q "Project X 9am block" "$VAULT/wiki/me.md" && fail "undo did not remove written fact"
grep -q "existing item" "$VAULT/wiki/me.md" || fail "undo destroyed pre-existing content"
grep -q "me.md" "$VAULT/wiki/index.md" && fail "undo did not remove index entry"
echo "PASS: stage 4 — undo reverted vault + index, preserved originals"

# === Stage 5: queue untouched by undo (queue is separate) ===
grep -q "Replace old item" "$QUEUE_FILE" || fail "undo wrongly cleared queue"
grep -q "Maybe try new framework" "$QUEUE_FILE" || fail "undo wrongly cleared queue"
echo "PASS: stage 5 — queue untouched by undo"

echo
echo "All e2e pipeline tests passed."
