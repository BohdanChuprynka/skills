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

# ── test 2 (M6): processed log renamed to .applied-* → re-apply is blocked ────
[ ! -f "$UNDO_LOG" ] || fail "undo log not renamed after apply (re-apply protection missing)"
APPLIED=$(ls "$UNDO_LOG".applied-* 2>/dev/null | head -1)
[ -n "$APPLIED" ] || fail "no .applied-* sibling created after undo"
# Re-applying the original (now-missing) path must fail loudly, not silently corrupt the page
if HOME="$VAULT" "$UNDO" "$UNDO_LOG" 2>/dev/null; then fail "re-apply on renamed log unexpectedly succeeded"; fi
grep -q "original line" "$VAULT/wiki/page.md" || fail "re-apply attempt damaged the page"
echo "PASS: processed log renamed to .applied-*; re-apply blocked"

# ── test 3 (M6): --date resolves to \$HOME/.claude/dream-skill/undo/<date>.jsonl ─
FAKE_HOME=$(mktemp -d "/tmp/dream-undo-home-XXXXXX")
mkdir -p "$FAKE_HOME/.claude/dream-skill/undo"
DATED_VAULT="$VAULT/dated"; mkdir -p "$DATED_VAULT/wiki"
printf '# Page\n\n## Notes\n\n- keep me\n- dated line\n' > "$DATED_VAULT/wiki/page.md"
jq -cn --arg v "$DATED_VAULT" '{action:"append", vault:$v, page:"wiki/page.md", content:"dated line"}' \
  > "$FAKE_HOME/.claude/dream-skill/undo/2026-06-01.jsonl"
HOME="$FAKE_HOME" "$UNDO" --date 2026-06-01 >/dev/null
grep -q "dated line" "$DATED_VAULT/wiki/page.md" && fail "--date: append not reverted"
grep -q "keep me"    "$DATED_VAULT/wiki/page.md" || fail "--date: reverted too much (original gone)"
[ ! -f "$FAKE_HOME/.claude/dream-skill/undo/2026-06-01.jsonl" ] || fail "--date: processed log not renamed"
rm -rf "$FAKE_HOME"
echo "PASS: --date resolves \$HOME/.claude/dream-skill/undo/<date>.jsonl, reverts, renames"
echo
echo "All apply-undo.sh tests passed."
