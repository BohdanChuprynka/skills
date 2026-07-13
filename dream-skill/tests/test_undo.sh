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
HOME="$FAKE_HOME" "$UNDO" --date 2026-06-01 --allow-legacy-date >/dev/null
grep -q "dated line" "$DATED_VAULT/wiki/page.md" && fail "--date: append not reverted"
grep -q "keep me"    "$DATED_VAULT/wiki/page.md" || fail "--date: reverted too much (original gone)"
[ ! -f "$FAKE_HOME/.claude/dream-skill/undo/2026-06-01.jsonl" ] || fail "--date: processed log not renamed"
rm -rf "$FAKE_HOME"
echo "PASS: --date resolves \$HOME/.claude/dream-skill/undo/<date>.jsonl, reverts, renames"

# ── test 4: apply-undo refuses an index_append entry pointing OUTSIDE its vault ──
# (defends a tampered/corrupt undo log; vault-writer stamps the vault into the entry)
OUT_DIR=$(mktemp -d "/tmp/dream-undo-outside-XXXXXX")
printf 'DELETEME\nkeep this\n' > "$OUT_DIR/outside-index.md"
TAMPER_LOG="$VAULT/tamper-index.jsonl"
printf '{"timestamp":"t","vault":"%s","index_file":"%s/outside-index.md","line":"DELETEME","action":"index_append"}\n' "$VAULT" "$OUT_DIR" > "$TAMPER_LOG"
if bash "$UNDO" "$TAMPER_LOG" >/dev/null 2>&1; then
  fail "apply-undo accepted an index entry outside its vault"
fi
grep -q "DELETEME" "$OUT_DIR/outside-index.md" || fail "apply-undo mutated a file OUTSIDE the vault via index_append"
[ -f "$TAMPER_LOG" ] || fail "failed prevalidation consumed the original undo log"
rm -rf "$OUT_DIR"
echo "PASS: fails closed on index_append outside its vault and preserves the log"

# ── test 5: a vault-LESS index_append entry is SKIPPED, not best-effort applied ──
# (round-4 gap: with no .vault field the entry must not fall through to a write)
OUT_DIR2=$(mktemp -d "/tmp/dream-undo-novault-XXXXXX")
printf 'KEEPME\n- attacker line\n' > "$OUT_DIR2/victim.md"
NOVAULT_LOG="$VAULT/novault-index.jsonl"
printf '{"timestamp":"t","index_file":"%s/victim.md","line":"- attacker line","action":"index_append"}\n' "$OUT_DIR2" > "$NOVAULT_LOG"
if bash "$UNDO" "$NOVAULT_LOG" >/dev/null 2>&1; then
  fail "apply-undo accepted a vault-less index entry"
fi
grep -q "attacker line" "$OUT_DIR2/victim.md" || fail "apply-undo mutated an outside file via a vault-less index entry"
[ -f "$NOVAULT_LOG" ] || fail "vault-less prevalidation failure consumed the undo log"
rm -rf "$OUT_DIR2"
echo "PASS: fails closed on a vault-less index_append and preserves the log"

# ── test 6: index_append with a symlinked INDEX_FILE → SKIPPED (defense-in-depth) ──
# apply-undo's mv semantics already prevent the outside write, but the explicit
# [ -L ] belt must reject it before reaching the write path.
OUT_DIR3=$(mktemp -d "/tmp/dream-undo-symidx-XXXXXX")
printf 'KEEPME\n' > "$OUT_DIR3/outside-index.md"
SYMIDX_VAULT=$(mktemp -d "/tmp/dream-undo-symidxvlt-XXXXXX")
mkdir -p "$SYMIDX_VAULT/wiki"
ln -s "$OUT_DIR3/outside-index.md" "$SYMIDX_VAULT/wiki/index.md"
SYMIDX_LOG="$VAULT/symidx-index.jsonl"
printf '{"timestamp":"t","vault":"%s","index_file":"%s/wiki/index.md","line":"- attacker","action":"index_append"}\n' \
  "$SYMIDX_VAULT" "$SYMIDX_VAULT" > "$SYMIDX_LOG"
if bash "$UNDO" "$SYMIDX_LOG" >/dev/null 2>&1; then
  fail "apply-undo accepted an index_append whose index_file is a leaf symlink"
fi
grep -q "attacker" "$OUT_DIR3/outside-index.md" && fail "apply-undo modified outside file via symlinked index"
[ -f "$SYMIDX_LOG" ] || fail "symlink prevalidation failure consumed the undo log"
rm -rf "$OUT_DIR3" "$SYMIDX_VAULT"
echo "PASS: fails closed on a symlinked index target and preserves the log"

# ── test 7: one malformed event blocks the complete log before any mutation ─
PRE_VAULT="$VAULT/prevalidate"; mkdir -p "$PRE_VAULT/wiki"
printf '# Page\n\n## Notes\n\n- valid rollback target\n- keep unchanged\n' > "$PRE_VAULT/wiki/page.md"
cp "$PRE_VAULT/wiki/page.md" "$PRE_VAULT/wiki/page.before"
PRE_LOG="$VAULT/prevalidate.jsonl"
jq -cn --arg v "$PRE_VAULT" \
  '{action:"append",vault:$v,page:"wiki/page.md",content:"valid rollback target"}' > "$PRE_LOG"
printf '%s\n' '{"action":"future_unknown_action"}' >> "$PRE_LOG"
if bash "$UNDO" "$PRE_LOG" >/dev/null 2>&1; then
  fail "unknown action unexpectedly passed full-log prevalidation"
fi
cmp -s "$PRE_VAULT/wiki/page.before" "$PRE_VAULT/wiki/page.md" \
  || fail "a valid earlier event mutated the vault before a later malformed event failed"
[ -f "$PRE_LOG" ] || fail "malformed full-log prevalidation consumed the undo log"
echo "PASS: malformed later event prevents every mutation and preserves the log"

# ── test 8: missing action-specific fields fail closed ─────────────────────
MISSING_LOG="$VAULT/missing-field.jsonl"
jq -cn --arg v "$PRE_VAULT" \
  '{action:"append",vault:$v,content:"valid rollback target"}' > "$MISSING_LOG"
if bash "$UNDO" "$MISSING_LOG" >/dev/null 2>&1; then
  fail "append event missing page unexpectedly passed validation"
fi
cmp -s "$PRE_VAULT/wiki/page.before" "$PRE_VAULT/wiki/page.md" \
  || fail "missing-field event mutated its target"
[ -f "$MISSING_LOG" ] || fail "missing-field failure consumed the undo log"
echo "PASS: missing action-specific fields fail closed"

# ── test 9: stale expected content fails before mutation ───────────────────
STALE_LOG="$VAULT/stale-state.jsonl"
jq -cn --arg v "$PRE_VAULT" \
  '{action:"append",vault:$v,page:"wiki/page.md",content:"not present anymore"}' > "$STALE_LOG"
if bash "$UNDO" "$STALE_LOG" >/dev/null 2>&1; then
  fail "stale expected content unexpectedly passed rollback preflight"
fi
cmp -s "$PRE_VAULT/wiki/page.before" "$PRE_VAULT/wiki/page.md" \
  || fail "stale-state preflight mutated the page"
[ -f "$STALE_LOG" ] || fail "stale-state failure consumed the undo log"
echo "PASS: stale expected content fails preflight without mutation"

# ── test 10: reviewed cleanup remove event still round-trips successfully ──
CLEAN_VAULT="$VAULT/cleanup"; mkdir -p "$CLEAN_VAULT/wiki"
printf '# Cleanup\n\n## Notes\n\n- keep before\n- cleanup target\n- keep after\n' > "$CLEAN_VAULT/wiki/page.md"
CLEAN_LOG="$VAULT/cleanup.jsonl"
"$WRITER" --vault "$CLEAN_VAULT" --page "wiki/page.md" --section "Notes" \
  --content "cleanup target" --mode remove --undo-log "$CLEAN_LOG"
grep -Fq -- '- cleanup target' "$CLEAN_VAULT/wiki/page.md" \
  && fail "cleanup setup did not remove its target"
bash "$UNDO" "$CLEAN_LOG" >/dev/null
grep -Fq -- '- cleanup target' "$CLEAN_VAULT/wiki/page.md" \
  || fail "cleanup remove event did not restore its exact line"
[ ! -f "$CLEAN_LOG" ] || fail "successful cleanup rollback did not consume its log"
echo "PASS: cleanup remove event succeeds through hardened rollback"

# ── test 11: run-scoped selector accepts the shared restrictive grammar ────
MODERN_HOME="$VAULT/modern-home"; MODERN_VAULT="$VAULT/modern-vault"
mkdir -p "$MODERN_HOME/undo" "$MODERN_VAULT/wiki"
printf '# Modern\n\n## Notes\n' > "$MODERN_VAULT/wiki/page.md"
MODERN_RUN="dream-all-2026-06-01-2026-06-02_123"
MODERN_LOG="$MODERN_HOME/undo/$MODERN_RUN.jsonl"
"$WRITER" --vault "$MODERN_VAULT" --page "wiki/page.md" --section "Notes" \
  --content "modern fact" --undo-log "$MODERN_LOG" \
  --run-id "$MODERN_RUN" --candidate-id "candidate-123"
bash "$UNDO" --home "$MODERN_HOME" --run-id "$MODERN_RUN" >/dev/null
grep -Fq -- '- modern fact' "$MODERN_VAULT/wiki/page.md" \
  && fail "run-scoped selector did not revert its event"
echo "PASS: run-scoped selector accepts alphanumeric/dot/underscore/hyphen IDs"

# ── test 12: receipt-incompatible colon IDs are rejected before path lookup ─
if bash "$UNDO" --home "$MODERN_HOME" --run-id 'dream:unsafe' >/dev/null 2>&1; then
  fail "colon-bearing run ID unexpectedly passed restrictive grammar"
fi
echo "PASS: run-scoped selector rejects colon-bearing IDs"

echo
echo "All apply-undo.sh tests passed."
