#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRITER="$SKILL_DIR/scripts/vault-writer.sh"
UNDO="$SKILL_DIR/scripts/apply-undo.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VAULT="$TMP/vault"
HOME_DIR="$TMP/state"
mkdir -p "$VAULT/wiki" "$HOME_DIR/undo"
TODAY=$(date +%F)

fail() { echo "test_write_freshness: $*" >&2; exit 1; }

# Existing updated field: forward write refreshes it and undo restores the exact
# prior YAML line together with removing the content.
cat > "$VAULT/wiki/page.md" <<'EOF'
---
title: Page
updated: 2025-01-02 # preserve me exactly
status: active
---
# Page

## Facts

- Original
EOF
LOG="$HOME_DIR/undo/run-a.jsonl"
"$WRITER" --vault "$VAULT" --page wiki/page.md --section Facts \
  --content 'Added' --undo-log "$LOG" --run-id run-a --candidate-id c-add --no-index-update
grep -Fxq "updated: $TODAY" "$VAULT/wiki/page.md" || fail "append did not refresh updated"
grep -Fxq 'status: active' "$VAULT/wiki/page.md" || fail "append damaged other YAML"
jq -e '.frontmatter.present_before == true and .frontmatter.had_updated_before == true and .frontmatter.updated_before == "updated: 2025-01-02 # preserve me exactly" and .run_id == "run-a" and .candidate_id == "c-add"' "$LOG" >/dev/null \
  || fail "undo event did not preserve prior freshness/provenance"
"$UNDO" --home "$HOME_DIR" --run-id run-a >/dev/null
grep -Fxq 'updated: 2025-01-02 # preserve me exactly' "$VAULT/wiki/page.md" \
  || fail "undo did not restore exact prior updated field"
! grep -Fxq -- '- Added' "$VAULT/wiki/page.md" || fail "undo did not remove append"

# Existing YAML without updated: forward write adds it; atomic undo removes it
# while restoring the replaced complete Markdown line.
cat > "$VAULT/wiki/replace.md" <<'EOF'
---
title: Replace
status: active
---
# Replace

## Facts

- Old fact
EOF
REPLACE_LOG="$HOME_DIR/undo/run-replace.jsonl"
"$WRITER" --vault "$VAULT" --page wiki/replace.md --section Facts \
  --mode replace --old-content '- Old fact' --content '- New fact' \
  --undo-log "$REPLACE_LOG" --run-id run-replace --candidate-id c-replace --no-index-update
grep -Fxq "updated: $TODAY" "$VAULT/wiki/replace.md" || fail "replace did not add updated"
jq -e '.frontmatter.had_updated_before == false and .frontmatter.updated_before == null' "$REPLACE_LOG" >/dev/null \
  || fail "replace undo did not record absent prior updated field"
"$UNDO" --home "$HOME_DIR" --run-id run-replace >/dev/null
grep -Fxq -- '- Old fact' "$VAULT/wiki/replace.md" || fail "replace undo did not restore old line"
! grep -q '^updated:' "$VAULT/wiki/replace.md" || fail "replace undo did not remove Dream-added updated"
grep -Fxq 'status: active' "$VAULT/wiki/replace.md" || fail "replace undo damaged YAML"

# No-frontmatter pages retain their schema. A no-op also must not manufacture a
# freshness mutation or undo row.
cat > "$VAULT/wiki/plain.md" <<'EOF'
# Plain

## Facts

- Existing
EOF
PLAIN_LOG="$HOME_DIR/undo/run-plain.jsonl"
"$WRITER" --vault "$VAULT" --page wiki/plain.md --section Facts \
  --content 'New plain fact' --undo-log "$PLAIN_LOG" --run-id run-plain --candidate-id c-plain --no-index-update
[ "$(sed -n '1p' "$VAULT/wiki/plain.md")" = '# Plain' ] || fail "writer imposed YAML on plain page"
! grep -q '^updated:' "$VAULT/wiki/plain.md" || fail "plain page received updated field"
before=$(wc -l < "$PLAIN_LOG" | tr -d ' ')
"$WRITER" --vault "$VAULT" --page wiki/plain.md --section Facts \
  --content 'New plain fact' --undo-log "$PLAIN_LOG" --run-id run-plain --candidate-id c-plain --no-index-update
[ "$(wc -l < "$PLAIN_LOG" | tr -d ' ')" = "$before" ] || fail "no-op created undo row"

# Index mutation follows the same freshness/undo contract.
cat > "$VAULT/wiki/index.md" <<'EOF'
---
title: Index
updated: 2024-12-31
---
# Index
EOF
cat > "$VAULT/wiki/indexed.md" <<'EOF'
---
title: Indexed
updated: 2024-11-30
---
# Indexed

## Facts
EOF
INDEX_LOG="$HOME_DIR/undo/run-index.jsonl"
"$WRITER" --vault "$VAULT" --page wiki/indexed.md --section Facts \
  --content 'Indexed fact' --undo-log "$INDEX_LOG" --run-id run-index --candidate-id c-index \
  --index-label Indexed
grep -Fxq "updated: $TODAY" "$VAULT/wiki/index.md" || fail "index mutation did not refresh updated"
[ "$(jq -s 'length' "$INDEX_LOG")" = "2" ] || fail "index mutation did not create two attributable undo events"
"$UNDO" --home "$HOME_DIR" --run-id run-index >/dev/null
grep -Fxq 'updated: 2024-12-31' "$VAULT/wiki/index.md" || fail "index undo did not restore updated"
! grep -q 'indexed.md' "$VAULT/wiki/index.md" || fail "index undo did not remove link"
grep -Fxq 'updated: 2024-11-30' "$VAULT/wiki/indexed.md" || fail "page undo did not restore updated"

# Run-scoped rollback verifies every event before any mutation.
cat > "$VAULT/wiki/mismatch.md" <<'EOF'
# Mismatch

## Facts

- Keep
- Candidate
EOF
printf '{"action":"append","run_id":"another-run","candidate_id":"c","vault":"%s","page":"wiki/mismatch.md","content":"Candidate"}\n' "$VAULT" \
  > "$HOME_DIR/undo/requested-run.jsonl"
if "$UNDO" --home "$HOME_DIR" --run-id requested-run >/dev/null 2>&1; then
  fail "run-scoped rollback accepted a mismatched event"
fi
grep -Fxq -- '- Candidate' "$VAULT/wiki/mismatch.md" || fail "mismatch preflight mutated the page"

echo "test_write_freshness: ok"
