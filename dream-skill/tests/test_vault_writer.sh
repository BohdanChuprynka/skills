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

# Test 13: apply-undo skips a replace whose target line is already gone (no overcount, no corruption)
cat > "$VAULT/wiki/gone.md" <<'EOF'
# Gone

## Status
- unrelated line
EOF
printf '{"timestamp":"t","vault":"%s","page":"wiki/gone.md","section":"Status","old_content":"orig","content":"already-gone","action":"replace"}\n' "$VAULT" > "$VAULT/undo-gone.jsonl"
OUT=$(bash "$SCRIPT_DIR/../scripts/apply-undo.sh" "$VAULT/undo-gone.jsonl")
echo "$OUT" | grep -q "skipped: 1" || fail "apply-undo should skip a replace whose forward line is absent (got: $OUT)"
grep -q "^- unrelated line$" "$VAULT/wiki/gone.md" || fail "apply-undo corrupted an unrelated page"
echo "PASS: apply-undo skips already-reverted replace"

# Test 14: --dry-run append → page byte-identical, undo log not created/changed
DRYRUN_PAGE="$VAULT/wiki/dryrun.md"
cat > "$DRYRUN_PAGE" <<'EOF'
# DryRun

## Notes

- existing line
EOF

BEFORE_HASH=$(shasum -a 256 "$DRYRUN_PAGE" | awk '{print $1}')
BEFORE_UNDO_LINES=0
DRYRUN_UNDO="$VAULT/undo-dryrun.jsonl"
[ -f "$DRYRUN_UNDO" ] && BEFORE_UNDO_LINES=$(wc -l < "$DRYRUN_UNDO")

"$WRITER" \
  --vault    "$VAULT" \
  --page     "wiki/dryrun.md" \
  --section  "Notes" \
  --content  "new dry-run line" \
  --mode     append \
  --undo-log "$DRYRUN_UNDO" \
  --dry-run

AFTER_HASH=$(shasum -a 256 "$DRYRUN_PAGE" | awk '{print $1}')
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "--dry-run append: page was modified (hashes differ)"
AFTER_UNDO_LINES=0
[ -f "$DRYRUN_UNDO" ] && AFTER_UNDO_LINES=$(wc -l < "$DRYRUN_UNDO")
[ "$BEFORE_UNDO_LINES" -eq "$AFTER_UNDO_LINES" ] || fail "--dry-run append: undo log was written (lines before=$BEFORE_UNDO_LINES after=$AFTER_UNDO_LINES)"
echo "PASS: --dry-run append leaves page byte-identical, undo log untouched"

# Test 15: --dry-run replace → page byte-identical, undo log not created/changed
DRYRUN_REPLACE_PAGE="$VAULT/wiki/dryrun-replace.md"
cat > "$DRYRUN_REPLACE_PAGE" <<'EOF'
# DryRunReplace

## Status

- lives in Berlin
EOF

BEFORE_HASH=$(shasum -a 256 "$DRYRUN_REPLACE_PAGE" | awk '{print $1}')
DRYRUN_REPLACE_UNDO="$VAULT/undo-dryrun-replace.jsonl"
BEFORE_UNDO_LINES=0
[ -f "$DRYRUN_REPLACE_UNDO" ] && BEFORE_UNDO_LINES=$(wc -l < "$DRYRUN_REPLACE_UNDO")

"$WRITER" \
  --vault       "$VAULT" \
  --page        "wiki/dryrun-replace.md" \
  --section     "Status" \
  --content     "lives in Munich" \
  --mode        replace \
  --old-content "lives in Berlin" \
  --undo-log    "$DRYRUN_REPLACE_UNDO" \
  --dry-run

AFTER_HASH=$(shasum -a 256 "$DRYRUN_REPLACE_PAGE" | awk '{print $1}')
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "--dry-run replace: page was modified (hashes differ)"
AFTER_UNDO_LINES=0
[ -f "$DRYRUN_REPLACE_UNDO" ] && AFTER_UNDO_LINES=$(wc -l < "$DRYRUN_REPLACE_UNDO")
[ "$BEFORE_UNDO_LINES" -eq "$AFTER_UNDO_LINES" ] || fail "--dry-run replace: undo log was written"
echo "PASS: --dry-run replace leaves page byte-identical, undo log untouched"

# Test 16: new page creation sets a capitalized title (portable awk, not GNU sed \u)
# vault-writer auto-creates the file when --page references a non-existent page.
NEW_PAGE_PATH="$VAULT/wiki/auto-created-page.md"
rm -f "$NEW_PAGE_PATH"

"$WRITER" \
  --vault   "$VAULT" \
  --page    "wiki/auto-created-page.md" \
  --section "Notes" \
  --content "first entry for auto-created page" \
  --undo-log "$UNDO_LOG"

[ -f "$NEW_PAGE_PATH" ] || fail "new-page creation: file not created"
TITLE_LINE=$(head -1 "$NEW_PAGE_PATH")
# Basename "auto-created-page", tr '-' ' ' → "auto created page"
# awk toupper first char → "Auto created page"
# Expected heading: "# Auto created page"
[ "$TITLE_LINE" = "# Auto created page" ] \
  || fail "new-page creation: title line is '$TITLE_LINE' (expected '# Auto created page'; awk capitalize broken?)"
echo "PASS: new-page auto-created with correctly capitalized title (portable awk)"

# Test 17: path-traversal via '..' is refused — a hallucinated/malicious --page must
# not escape the vault root (.target.page is LLM-generated). See path-guard.sh.
OUTSIDE=$(mktemp -d "/tmp/dream-outside-XXXXXX")
printf '# victim\n\n## S\n- untouched\n' > "$OUTSIDE/victim.md"
ESCAPE_REL="../$(basename "$OUTSIDE")/victim.md"   # ../dream-outside-XXXX/victim.md from $VAULT
if "$WRITER" --vault "$VAULT" --page "$ESCAPE_REL" --section "S" \
     --content "PWNED" --undo-log "$UNDO_LOG" 2>/dev/null; then
  fail "path-traversal: writer accepted a '..' page escaping the vault"
fi
grep -q "PWNED" "$OUTSIDE/victim.md" && fail "path-traversal: writer modified a file OUTSIDE the vault"
grep -q "untouched" "$OUTSIDE/victim.md" || fail "path-traversal: victim file corrupted"
rm -rf "$OUTSIDE"
echo "PASS: refuses '..' page paths that escape the vault root"

# Test 18: absolute --page is refused (must be relative to the vault root)
ABS_TARGET="/tmp/dream-abs-escape-$$.md"
rm -f "$ABS_TARGET"
if "$WRITER" --vault "$VAULT" --page "$ABS_TARGET" --section "S" \
     --content "PWNED" 2>/dev/null; then
  fail "path-traversal: writer accepted an absolute --page"
fi
[ -f "$ABS_TARGET" ] && { rm -f "$ABS_TARGET"; fail "path-traversal: writer created an absolute-path file"; }
echo "PASS: refuses absolute page paths"

# Test 19: a symlinked leaf page target is refused — the create redirect must NOT
# follow the symlink and write outside the vault (the round-3 escape).
OUTL=$(mktemp -d "/tmp/dream-leaf-XXXXXX")
ln -s "$OUTL/escaped.md" "$VAULT/wiki/leaf-escape.md"
if "$WRITER" --vault "$VAULT" --page "wiki/leaf-escape.md" --section "S" \
     --content "PWNED" --no-index-update 2>/dev/null; then
  rm -f "$VAULT/wiki/leaf-escape.md"; rm -rf "$OUTL"
  fail "leaf-symlink: writer wrote through a symlinked page target"
fi
[ -e "$OUTL/escaped.md" ] && { rm -f "$VAULT/wiki/leaf-escape.md"; rm -rf "$OUTL"; fail "leaf-symlink: created a file OUTSIDE the vault"; }
rm -f "$VAULT/wiki/leaf-escape.md"; rm -rf "$OUTL"
echo "PASS: refuses a symlinked leaf page target (no escape)"

echo
echo "All vault-writer.sh tests passed."
