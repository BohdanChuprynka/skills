#!/usr/bin/env bash
# Test: vault-writer.sh add-only writes + idempotent index updates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="$SCRIPT_DIR/../scripts/vault-writer.sh"

[ -x "$WRITER" ] || { echo "FAIL: vault-writer.sh missing or not executable"; exit 1; }

# Setup mock vault in tmp
VAULT=$(mktemp -d "/tmp/dream-vault-test-XXXXXX")
trap 'rm -rf "$VAULT"' EXIT

mkdir -p "$VAULT/wiki"

cat > "$VAULT/wiki/index.md" <<'EOF'
# Wiki Index

- [Existing Page](existing.md) — already linked, idempotency target
EOF

cat > "$VAULT/wiki/existing.md" <<'EOF'
# Existing Page

## Current Focus

- old item
EOF

cat > "$VAULT/wiki/new-page.md" <<'EOF'
# New Page

## Notes
EOF

UNDO_LOG="$VAULT/undo.jsonl"

fail() { echo "FAIL: $*"; exit 1; }

# Test 1: append to existing section
"$WRITER" --vault "$VAULT" --page "wiki/existing.md" --section "Current Focus" \
  --content "new item from session" --undo-log "$UNDO_LOG"

grep -q "new item from session" "$VAULT/wiki/existing.md" || fail "content not appended"
grep -q "old item" "$VAULT/wiki/existing.md" || fail "old content removed (must be add-only)"
echo "PASS: append to existing section"

# Test 2: undo log written
[ -f "$UNDO_LOG" ] || fail "undo log not created"
grep -q "new item from session" "$UNDO_LOG" || fail "undo log missing entry"
echo "PASS: undo log written"

# Test 3: create new section if absent
"$WRITER" --vault "$VAULT" --page "wiki/existing.md" --section "Brand New Section" \
  --content "first entry" --undo-log "$UNDO_LOG"

grep -q "## Brand New Section" "$VAULT/wiki/existing.md" || fail "new section header not created"
grep -q "first entry" "$VAULT/wiki/existing.md" || fail "new section content missing"
echo "PASS: create new section"

# Test 4: idempotent — same content twice should not duplicate
COUNT_BEFORE=$(grep -c "new item from session" "$VAULT/wiki/existing.md")
"$WRITER" --vault "$VAULT" --page "wiki/existing.md" --section "Current Focus" \
  --content "new item from session" --undo-log "$UNDO_LOG"
COUNT_AFTER=$(grep -c "new item from session" "$VAULT/wiki/existing.md")
[ "$COUNT_BEFORE" -eq "$COUNT_AFTER" ] || fail "duplicate appended (expected idempotent)"
echo "PASS: idempotent append"

# Test 5: index update — new page should appear in wiki/index.md
"$WRITER" --vault "$VAULT" --page "wiki/new-page.md" --section "Notes" \
  --content "first note" --undo-log "$UNDO_LOG" \
  --index-label "New Page" --index-desc "Recently created via dream-skill"

grep -q "new-page.md" "$VAULT/wiki/index.md" || fail "new page not added to index"
echo "PASS: index updated for new page"

# Test 6: idempotent index — re-adding existing page is no-op
INDEX_LINES_BEFORE=$(wc -l < "$VAULT/wiki/index.md")
"$WRITER" --vault "$VAULT" --page "wiki/existing.md" --section "Current Focus" \
  --content "yet another item" --undo-log "$UNDO_LOG" \
  --index-label "Existing Page" --index-desc "should not double-link"
INDEX_LINES_AFTER=$(wc -l < "$VAULT/wiki/index.md")
[ "$INDEX_LINES_BEFORE" -eq "$INDEX_LINES_AFTER" ] || fail "index double-linked existing page"
echo "PASS: idempotent index (existing link)"

# Test 7: concurrent writes — 5 parallel appends to same page should all land
# (mkdir-lock serializes them; none get lost to read-modify-write race)
TEST_VAULT=$(mktemp -d "/tmp/dream-vault-concurrent-XXXXXX")
mkdir -p "$TEST_VAULT/wiki"
cat > "$TEST_VAULT/wiki/concurrent.md" <<'EOF'
# Concurrent

## Notes
EOF

export DREAM_VAULT_LOCK_DIR=$(mktemp -d "/tmp/dream-vault-locks-test-XXXXXX")

for i in 1 2 3 4 5; do
  "$WRITER" --vault "$TEST_VAULT" --page "wiki/concurrent.md" --section "Notes" \
    --content "parallel-line-$i" --undo-log "$TEST_VAULT/undo.jsonl" &
done
wait

LINES_LANDED=$(grep -c "^- parallel-line-" "$TEST_VAULT/wiki/concurrent.md" 2>/dev/null || echo 0)
[ "$LINES_LANDED" -eq 5 ] || fail "concurrent writes lost lines (landed=$LINES_LANDED, expected 5)"

rm -rf "$TEST_VAULT" "$DREAM_VAULT_LOCK_DIR"
unset DREAM_VAULT_LOCK_DIR
echo "PASS: 5 parallel writes serialized — no lost-update race"

# Test 8: replace mode swaps an existing line for new content
cat > "$VAULT/wiki/replace.md" <<'EOF'
# Replace

## Status
- lives in Berlin
EOF

"$WRITER" --vault "$VAULT" --page "wiki/replace.md" --section "Status" \
  --mode replace --old-content "lives in Berlin" \
  --content "lives in Munich (moved 2026-06)" --undo-log "$UNDO_LOG"

grep -q "lives in Munich" "$VAULT/wiki/replace.md" || fail "replace: new content not written"
grep -q "lives in Berlin" "$VAULT/wiki/replace.md" && fail "replace: old content still present"
echo "PASS: replace swaps an existing line"

# Test 9: replace is idempotent (re-running the same replace is a no-op)
"$WRITER" --vault "$VAULT" --page "wiki/replace.md" --section "Status" \
  --mode replace --old-content "lives in Berlin" \
  --content "lives in Munich (moved 2026-06)" --undo-log "$UNDO_LOG"
COUNT=$(grep -c "lives in Munich" "$VAULT/wiki/replace.md")
[ "$COUNT" -eq 1 ] || fail "replace not idempotent (count=$COUNT, expected 1)"
echo "PASS: replace is idempotent"

# Test 10: replace fails loudly when neither old nor new content is present
if "$WRITER" --vault "$VAULT" --page "wiki/replace.md" --section "Status" \
     --mode replace --old-content "nonexistent fact" \
     --content "whatever" --undo-log "$UNDO_LOG" 2>/dev/null; then
  fail "replace should exit non-zero when old content is absent"
fi
echo "PASS: replace fails when old content missing"

# Test 11: replace is reversible via apply-undo
UNDO_RT="$VAULT/undo-roundtrip.jsonl"
cat > "$VAULT/wiki/roundtrip.md" <<'EOF'
# Roundtrip

## Status
- status alpha
EOF

"$WRITER" --vault "$VAULT" --page "wiki/roundtrip.md" --section "Status" \
  --mode replace --old-content "status alpha" \
  --content "status beta" --undo-log "$UNDO_RT"

grep -q "replace" "$UNDO_RT" || fail "replace: undo entry not action=replace"

bash "$SCRIPT_DIR/../scripts/apply-undo.sh" "$UNDO_RT" >/dev/null

grep -q "^- status alpha$" "$VAULT/wiki/roundtrip.md" || fail "undo did not restore old line"
grep -q "status beta" "$VAULT/wiki/roundtrip.md" && fail "undo did not remove the replacement line"
echo "PASS: replace round-trips through apply-undo"

# Test 12: stale mode strikes through the old line and marks it superseded
cat > "$VAULT/wiki/stale.md" <<'EOF'
# Stale

## Priorities
- current internship at Aximon
EOF

"$WRITER" --vault "$VAULT" --page "wiki/stale.md" --section "Priorities" \
  --mode stale --old-content "current internship at Aximon" \
  --content "n/a" --undo-log "$VAULT/undo-stale.jsonl"

grep -q "~~current internship at Aximon~~" "$VAULT/wiki/stale.md" || fail "stale: line not struck through"
grep -q "superseded" "$VAULT/wiki/stale.md" || fail "stale: superseded marker missing"
echo "PASS: stale annotates the old line"

# And it reverses cleanly
bash "$SCRIPT_DIR/../scripts/apply-undo.sh" "$VAULT/undo-stale.jsonl" >/dev/null
grep -q "^- current internship at Aximon$" "$VAULT/wiki/stale.md" || fail "stale: undo did not restore original"
echo "PASS: stale round-trips through apply-undo"

echo
echo "All vault-writer.sh tests passed."
