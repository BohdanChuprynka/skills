#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$SKILL_DIR/scripts/validate-reconcile-batch.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/batch.json" <<'JSON'
{
  "batch_id": "reconcile-0001",
  "target": {"vault": "me", "page": "wiki/page.md"},
  "target_page": "# Page\n\n## Facts\n\n- Old fact\n",
  "candidates": [{
    "candidate_id": "c-stable",
    "candidate": {"content":"new fact","confidence":"high","source_chat":"x","source_date":"2026-07-01","memory_tier":"stable"},
    "route": {"vault":"me","page":"wiki/page.md","section":"Facts"}
  }]
}
JSON

cat > "$TMP/good.json" <<'JSON'
[{"candidate_id":"c-stable","decision":{"action":"supersede","mode":"replace","target":{"vault":"me","page":"wiki/page.md","section":"Facts"},"old_content":"- Old fact","content":"- New fact","candidate_confidence":"high","needs_review":true,"rationale":"newer user statement"}}]
JSON
"$VALIDATOR" --batch "$TMP/batch.json" < "$TMP/good.json" >/dev/null

jq '.[0].decision = {
  action:"duplicate", mode:"append",
  target:{vault:"wrong",page:"wrong.md",section:"Wrong"},
  old_content:"- Old fact", content:"model noise",
  candidate_confidence:"low", needs_review:true, rationale:"already present"
}' "$TMP/good.json" > "$TMP/noisy-duplicate.json"
"$VALIDATOR" --batch "$TMP/batch.json" < "$TMP/noisy-duplicate.json" > "$TMP/normalized.json"
jq -e '.[0].decision | .mode == "none" and .content == "" and
  (.old_content | not) and .target.vault == "me" and
  .candidate_confidence == "high" and .needs_review == false' "$TMP/normalized.json" >/dev/null

jq '.[0].decision.content = "New fact"' "$TMP/good.json" > "$TMP/bad-style.json"
"$VALIDATOR" --batch "$TMP/batch.json" < "$TMP/bad-style.json" > "$TMP/normalized-style.json"
jq -e '.[0].decision.content == "- new fact"' "$TMP/normalized-style.json" >/dev/null

jq '.[0].decision.old_content = "- Missing"' "$TMP/good.json" > "$TMP/bad-old.json"
if "$VALIDATOR" --batch "$TMP/batch.json" < "$TMP/bad-old.json" >/dev/null 2>&1; then
  echo "missing old line unexpectedly accepted" >&2
  exit 1
fi

echo "test_reconcile_contract: ok"
