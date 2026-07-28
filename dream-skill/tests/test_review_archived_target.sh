#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/vault/wiki" "$TMP/sidecars"
cat > "$TMP/vault/wiki/old.md" <<'MD'
---
status: archived
---
# Old

## Notes
MD

cat > "$TMP/sidecars/c-archived.json" <<EOF
{
  "candidate_id":"c-archived",
  "run_id":"dream-test",
  "vault_root":"$TMP/vault",
  "title":"The old fact",
  "target_display":"$TMP/vault/wiki/old.md#Notes",
  "target":{"vault":"projects","page":"wiki/old.md","section":"Notes"},
  "action":"new",
  "candidate_confidence":"high",
  "content":"The old fact must not be written.",
  "needs_review":true
}
EOF
cat > "$TMP/decisions.json" <<'JSON'
{"c-archived":"approve"}
JSON
cat > "$TMP/review-input.json" <<'JSON'
{"entries":[{"id":"c-archived"}]}
JSON

if "$SKILL_DIR/scripts/apply-review-decisions.sh" \
  --decisions "$TMP/decisions.json" \
  --review-input "$TMP/review-input.json" \
  --sidecars-dir "$TMP/sidecars" \
  --undo-log "$TMP/undo.jsonl" >"$TMP/out" 2>"$TMP/err"; then
  echo "expected archived-target approval to fail" >&2
  exit 1
fi

grep -q "archived" "$TMP/err"
if grep -Fq "old fact must not" "$TMP/vault/wiki/old.md"; then
  echo "archived target was written" >&2
  exit 1
fi
[ -f "$TMP/sidecars/c-archived.json" ]

cat > "$TMP/direct.json" <<'JSON'
{
  "run_id":"dream-direct",
  "action":"new",
  "target":{"vault":"projects","page":"wiki/old.md","section":"Notes"},
  "content":"A direct stale write must not happen.",
  "candidate_confidence":"high",
  "needs_review":false
}
JSON
if "$SKILL_DIR/scripts/apply-decision.sh" --vault "$TMP/vault" --decision "$TMP/direct.json" \
  --undo-log "$TMP/dream-direct.jsonl" --candidate-id c-direct >"$TMP/direct-out" 2>"$TMP/direct-err"; then
  echo "expected direct archived-target apply to fail" >&2
  exit 1
fi
grep -q "archived" "$TMP/direct-err"
if grep -Fq "direct stale write" "$TMP/vault/wiki/old.md"; then
  echo "direct archived target was written" >&2
  exit 1
fi

echo "test_review_archived_target: ok"
