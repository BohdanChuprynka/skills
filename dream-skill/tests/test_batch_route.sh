#!/usr/bin/env bash
# Tests deterministic ROUTE batching and route-output validation. No model calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SCRIPT_DIR/../scripts/build-route-batches.py"
VALIDATE="$SCRIPT_DIR/../scripts/validate-route-batch.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

for s in "$BUILD" "$VALIDATE"; do
  [ -x "$s" ] || fail "script missing or not executable: $s"
done

TMPROOT=$(mktemp -d "/tmp/dream-route-batch-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

CANDIDATES="$TMPROOT/candidates.json"
cat > "$CANDIDATES" <<'JSON'
[
  {"content":"uses PyTorch Lightning","confidence":"high","source_chat":"a.jsonl","source_date":"2026-06-01","suggested_section":"Deep Learning","memory_tier":"stable"},
  {"content":"switched aximon auth to sessions","confidence":"high","source_chat":"b.jsonl","source_date":"2026-06-02","suggested_section":"Architecture","memory_tier":"current"},
  {"content":"Marcus is a prospect","confidence":"medium","source_chat":"c.jsonl","source_date":"2026-06-03","suggested_section":"Pipeline","memory_tier":"stable"},
  {"content":"cafeteria closes at 7pm","confidence":"low","source_chat":"d.jsonl","source_date":"2026-06-04","memory_tier":"stable"}
]
JSON

BATCHES="$TMPROOT/route-batches.json"
"$BUILD" --size 2 < "$CANDIDATES" > "$BATCHES"

[ "$(jq 'length' "$BATCHES")" = "2" ] || fail "expected 2 route batches"
[ "$(jq -r '.[0].batch_id' "$BATCHES")" = "route-0001" ] || fail "wrong first batch id"
[ "$(jq -r '.[0].candidates[0].candidate_id' "$BATCHES")" = "c000001" ] || fail "missing stable first candidate id"
[ "$(jq -r '.[1].candidates[1].candidate_id' "$BATCHES")" = "c000004" ] || fail "missing stable fourth candidate id"
echo "PASS: build-route-batches creates stable candidate_id chunks"

BATCH1="$TMPROOT/route-batch-1.json"
jq '.[0]' "$BATCHES" > "$BATCH1"

ROUTE_OUT="$TMPROOT/route-out.json"
cat > "$ROUTE_OUT" <<'JSON'
[
  {"candidate_id":"c000001","status":"routed","vault":"me","page":"wiki/skills/deep-learning.md","section":"Deep Learning","routing_confidence":"high"},
  {"candidate_id":"c000002","status":"routed","vault":"projects","page":"wiki/aximon.md","section":"Architecture","routing_confidence":"high"}
]
JSON

JOINED=$("$VALIDATE" --batch "$BATCH1" < "$ROUTE_OUT")
[ "$(printf '%s' "$JOINED" | jq 'length')" = "2" ] || fail "joined route output should have two records"
[ "$(printf '%s' "$JOINED" | jq -r '.[0].candidate.content')" = "uses PyTorch Lightning" ] \
  || fail "joined output lost original candidate content"
[ "$(printf '%s' "$JOINED" | jq -r '.[1].route.page')" = "wiki/aximon.md" ] \
  || fail "joined output lost route decision"
echo "PASS: validate-route-batch joins valid batched ROUTE output to candidates"

MISSING_OUT="$TMPROOT/route-missing.json"
cat > "$MISSING_OUT" <<'JSON'
[
  {"candidate_id":"c000001","status":"routed","vault":"me","page":"wiki/skills/deep-learning.md","section":"Deep Learning","routing_confidence":"high"}
]
JSON
if "$VALIDATE" --batch "$BATCH1" < "$MISSING_OUT" >/dev/null 2>&1; then
  fail "validator accepted output missing c000002"
fi
echo "PASS: validate-route-batch rejects dropped candidate_id"

BAD_NULLS="$TMPROOT/route-bad-nulls.json"
cat > "$BAD_NULLS" <<'JSON'
[
  {"candidate_id":"c000001","status":"gap","vault":"me","page":null,"section":null,"routing_confidence":"low"},
  {"candidate_id":"c000002","status":"routed","vault":"projects","page":"wiki/aximon.md","section":"Architecture","routing_confidence":"high"}
]
JSON
if "$VALIDATE" --batch "$BATCH1" < "$BAD_NULLS" >/dev/null 2>&1; then
  fail "validator accepted gap route with non-null vault"
fi
echo "PASS: validate-route-batch rejects invalid gap/ambiguous null contract"

EXTRA_KEY="$TMPROOT/route-extra-key.json"
cat > "$EXTRA_KEY" <<'JSON'
[
  {"candidate_id":"c000001","status":"routed","vault":"me","page":"wiki/skills/deep-learning.md","section":"Deep Learning","routing_confidence":"high","canonical_path":"wiki/skills/deep-learning.md"},
  {"candidate_id":"c000002","status":"routed","vault":"projects","page":"wiki/aximon.md","section":"Architecture","routing_confidence":"high"}
]
JSON
if "$VALIDATE" --batch "$BATCH1" < "$EXTRA_KEY" >/dev/null 2>&1; then
  fail "validator accepted route output with unexpected extra key"
fi
echo "PASS: validate-route-batch rejects unexpected route output keys"

BAD_INPUT="$TMPROOT/bad-candidates.json"
cat > "$BAD_INPUT" <<'JSON'
[{"content":"missing date","confidence":"high","source_chat":"x.jsonl"}]
JSON
if "$BUILD" --size 2 < "$BAD_INPUT" >/dev/null 2>&1; then
  fail "build-route-batches accepted candidate missing required source_date"
fi
echo "PASS: build-route-batches rejects structurally invalid candidates"

echo "All route batching tests passed."
