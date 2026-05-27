#!/usr/bin/env bash
# Test: apply-undo.sh reverses vault-writer appends
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="$SCRIPT_DIR/../scripts/vault-writer.sh"
UNDO="$SCRIPT_DIR/../scripts/apply-undo.sh"

[ -x "$WRITER" ] || { echo "FAIL: vault-writer.sh missing"; exit 1; }
[ -x "$UNDO" ] || { echo "FAIL: apply-undo.sh missing"; exit 1; }

VAULT=$(mktemp -d "/tmp/dream-undo-test-XXXXXX")
trap 'rm -rf "$VAULT"' EXIT

mkdir -p "$VAULT/wiki"
cat > "$VAULT/wiki/index.md" <<'EOF'
# Wiki Index
EOF
cat > "$VAULT/wiki/page.md" <<'EOF'
# Page

## Notes

- original line
EOF

UNDO_LOG="$VAULT/undo.jsonl"

fail() { echo "FAIL: $*"; exit 1; }

# Write 2 entries
"$WRITER" --vault "$VAULT" --page "wiki/page.md" --section "Notes" \
  --content "first added" --undo-log "$UNDO_LOG"
"$WRITER" --vault "$VAULT" --page "wiki/page.md" --section "Notes" \
  --content "second added" --undo-log "$UNDO_LOG" \
  --index-label "Page" --index-desc "test page"

# Verify both writes are present
grep -q "first added" "$VAULT/wiki/page.md" || fail "first write missing pre-undo"
grep -q "second added" "$VAULT/wiki/page.md" || fail "second write missing pre-undo"
grep -q "page.md" "$VAULT/wiki/index.md" || fail "index entry missing pre-undo"

# Apply undo
"$UNDO" "$UNDO_LOG"

# Verify both writes reverted
grep -q "first added" "$VAULT/wiki/page.md" && fail "first write still present after undo"
grep -q "second added" "$VAULT/wiki/page.md" && fail "second write still present after undo"
grep -q "page.md" "$VAULT/wiki/index.md" && fail "index entry still present after undo"

# Verify original content preserved
grep -q "original line" "$VAULT/wiki/page.md" || fail "undo deleted pre-existing original line"

echo "PASS: undo reverts vault writes + index entry, preserves originals"
echo
echo "All apply-undo.sh tests passed."
