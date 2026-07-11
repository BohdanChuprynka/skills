#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/vault/wiki"
printf '# One\n\n## Facts\n\n- Existing one\n' > "$TMP/vault/wiki/one.md"
printf '# Two\n\n## Facts\n\n- Existing two\n' > "$TMP/vault/wiki/two.md"
cat > "$TMP/config.toml" <<EOF
[vaults.test]
root = "$TMP/vault"
description = "test"
EOF
cat > "$TMP/routed.json" <<'JSON'
[
  {"candidate_id":"c-one","candidate":{"content":"New one","confidence":"high","source_chat":"x","source_date":"2026-07-01","memory_tier":"stable"},"route":{"status":"routed","vault":"test","page":"wiki/one.md","section":"Facts","routing_confidence":"high"}},
  {"candidate_id":"c-two","candidate":{"content":"Existing two","confidence":"high","source_chat":"x","source_date":"2026-07-01","memory_tier":"stable"},"route":{"status":"routed","vault":"test","page":"wiki/two.md","section":"Facts","routing_confidence":"high"}}
]
JSON

"$SKILL_DIR/scripts/build-reconcile-batches.py" --config "$TMP/config.toml" \
  --max-packed-context-chars 10000 < "$TMP/routed.json" > "$TMP/batches.json"
jq -e 'length == 1 and .[0].target_page_scope == "multiple-isolated-page-contexts" and
  (.[0].page_groups | length) == 2 and (.[0].candidates | length) == 2' "$TMP/batches.json" >/dev/null
jq '.[0]' "$TMP/batches.json" > "$TMP/batch.json"
jq '[.candidates[] | {
  candidate_id,
  decision:{
    action:(if .candidate_id == "c-two" then "duplicate" else "new" end),
    mode:"wrong",
    target:{vault:"wrong",page:"wrong",section:"wrong"},
    content:.candidate.content,
    candidate_confidence:"low",
    needs_review:true,
    rationale:"fixture"
  }
}]' "$TMP/batch.json" > "$TMP/output.json"
"$SKILL_DIR/scripts/validate-reconcile-batch.py" --batch "$TMP/batch.json" \
  < "$TMP/output.json" > "$TMP/validated.json"
jq -e 'length == 2 and .[0].decision.target.page == "wiki/one.md" and
  .[1].decision.target.page == "wiki/two.md" and .[1].decision.content == ""' "$TMP/validated.json" >/dev/null

echo "test_reconcile_packing: ok"
