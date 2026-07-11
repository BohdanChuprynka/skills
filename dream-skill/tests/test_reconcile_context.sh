#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER="$SKILL_DIR/scripts/build-reconcile-batches.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/vault/wiki"

{
  printf '# Page\n\n## Facts\n\n'
  for i in $(seq 1 100); do printf -- '- Fact line %s about retrieval\n' "$i"; done
  printf '\n## Other\n\n- Unrelated value\n'
} > "$TMP/vault/wiki/page.md"
cat > "$TMP/config.toml" <<EOF
[vaults.test]
root = "$TMP/vault"
description = "test"
EOF
cat > "$TMP/routed.json" <<'JSON'
[{"candidate_id":"c-test","candidate":{"content":"Fact line 75 about retrieval changed","confidence":"high","source_chat":"x","source_date":"2026-07-01","memory_tier":"stable"},"route":{"status":"routed","vault":"test","page":"wiki/page.md","section":"Facts","routing_confidence":"high"}}]
JSON

"$BUILDER" --config "$TMP/config.toml" --max-context-chars 600 < "$TMP/routed.json" > "$TMP/batches.json"
jq -e 'length == 1 and .[0].target_page_scope == "routed-section-plus-lexical-matches"' "$TMP/batches.json" >/dev/null
[ "$(jq -r '.[0].target_page | length' "$TMP/batches.json")" -le 600 ]
jq -e '.[0].allowed_old_lines | length > 0' "$TMP/batches.json" >/dev/null
jq -e '.[0].target_page_sha256 | test("^[0-9a-f]{64}$")' "$TMP/batches.json" >/dev/null

echo "test_reconcile_context: ok"
