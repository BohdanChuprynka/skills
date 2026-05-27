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

echo
echo "All vault-writer.sh tests passed."
