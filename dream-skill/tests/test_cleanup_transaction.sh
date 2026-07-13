#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPLY="$SKILL_DIR/scripts/apply-cleanup-manifest.py"
UNDO="$SKILL_DIR/scripts/apply-undo.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/source/wiki" "$TMP/target/wiki"
cat > "$TMP/source/wiki/page.md" <<'MD'
---
updated: 2026-01-01
---
# Source

## Facts

- Remove me.
- Rewrite me.
- Move me.
MD
cat > "$TMP/target/wiki/page.md" <<'MD'
---
updated: 2026-02-02
---
# Target

## Canonical
MD
cat > "$TMP/config.toml" <<EOF
[vaults.source]
root = "$TMP/source"
description = "Source"
[vaults.target]
root = "$TMP/target"
description = "Target"
EOF
cat > "$TMP/manifest.json" <<JSON
{
  "schema_version":1,
  "manifest_id":"test-cleanup",
  "recommendations":[
    {"cohort_index":1,"confidence":"high","recommended_action":"remove","source":{"vault":"source","page":"wiki/page.md","section":"Facts","content":"Remove me."}},
    {"cohort_index":2,"confidence":"high","recommended_action":"rewrite","recommended_content":"Rewritten.","source":{"vault":"source","page":"wiki/page.md","section":"Facts","content":"Rewrite me."}},
    {"cohort_index":3,"confidence":"high","recommended_action":"move","canonical_target":{"vault":"target","page":"wiki/page.md","section":"Canonical"},"source":{"vault":"source","page":"wiki/page.md","section":"Facts","content":"Move me."}}
  ]
}
JSON

cp "$TMP/source/wiki/page.md" "$TMP/source-before.md"
cp "$TMP/target/wiki/page.md" "$TMP/target-before.md"
"$APPLY" --manifest "$TMP/manifest.json" --config "$TMP/config.toml" --home "$TMP/home" --run-id cleanup-test > "$TMP/preview.json"
jq -e '.mode == "dry-run" and .recommendations == 3 and .actions.move == 1 and .actions.remove == 1 and .actions.rewrite == 1' "$TMP/preview.json" >/dev/null
cmp -s "$TMP/source-before.md" "$TMP/source/wiki/page.md"
cmp -s "$TMP/target-before.md" "$TMP/target/wiki/page.md"

LONG_RUN_ID=$(printf 'a%.0s' {1..129})
if "$APPLY" --manifest "$TMP/manifest.json" --config "$TMP/config.toml" \
  --home "$TMP/home" --run-id "$LONG_RUN_ID" >/dev/null 2>&1; then
  echo "cleanup accepted a run ID that its rollback command would reject" >&2
  exit 1
fi

"$APPLY" --manifest "$TMP/manifest.json" --config "$TMP/config.toml" --home "$TMP/home" --run-id cleanup-test --apply > "$TMP/applied.json"
! rg -Fq -- '- Remove me.' "$TMP/source/wiki/page.md"
! rg -Fq -- '- Rewrite me.' "$TMP/source/wiki/page.md"
! rg -Fq -- '- Move me.' "$TMP/source/wiki/page.md"
rg -Fq -- '- Rewritten.' "$TMP/source/wiki/page.md"
rg -Fq -- '- Move me.' "$TMP/target/wiki/page.md"
rg -Fq -- "updated: $(date +%F)" "$TMP/source/wiki/page.md"
rg -Fq -- "updated: $(date +%F)" "$TMP/target/wiki/page.md"
[ "$(wc -l < "$TMP/home/undo/cleanup-test.jsonl" | tr -d ' ')" = "4" ]
jq -se 'map(.action) | sort == ["append","remove","remove","replace"]' "$TMP/home/undo/cleanup-test.jsonl" >/dev/null
jq -e '.status == "applied" and .run_id == "cleanup-test"' "$TMP/home/cleanup/runs/cleanup-test.json" >/dev/null

"$UNDO" --home "$TMP/home" --run-id cleanup-test >/dev/null
cmp -s "$TMP/source-before.md" "$TMP/source/wiki/page.md"
cmp -s "$TMP/target-before.md" "$TMP/target/wiki/page.md"

# Receipt persistence is part of the transaction.  Force its parent path to be
# unusable only after the backup/undo roots can be created, so the apply reaches
# and mutates the vault before receipt publication fails.
mkdir -p "$TMP/receipt-failure-home/cleanup"
touch "$TMP/receipt-failure-home/cleanup/runs"
if "$APPLY" \
  --manifest "$TMP/manifest.json" \
  --config "$TMP/config.toml" \
  --home "$TMP/receipt-failure-home" \
  --run-id cleanup-receipt-failure \
  --apply > "$TMP/receipt-failure.stdout" 2> "$TMP/receipt-failure.stderr"; then
  echo "expected receipt-path failure" >&2
  exit 1
fi
cmp -s "$TMP/source-before.md" "$TMP/source/wiki/page.md"
cmp -s "$TMP/target-before.md" "$TMP/target/wiki/page.md"
[ ! -e "$TMP/receipt-failure-home/undo/cleanup-receipt-failure.jsonl" ]
[ -s "$TMP/receipt-failure-home/undo/cleanup-receipt-failure.jsonl.rolled-back" ]
jq -se 'length == 4 and (map(.action) | sort == ["append","remove","remove","replace"])' \
  "$TMP/receipt-failure-home/undo/cleanup-receipt-failure.jsonl.rolled-back" >/dev/null
[ ! -e "$TMP/receipt-failure-home/cleanup/runs/cleanup-receipt-failure.json" ]
rg -Fq 'transaction failed and was rolled back' "$TMP/receipt-failure.stderr"

echo "test_cleanup_transaction: ok"
