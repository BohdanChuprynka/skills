#!/usr/bin/env bash
# Tests page-grouped RECONCILE batching and reconcile-output validation. No model calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SCRIPT_DIR/../scripts/build-reconcile-batches.py"
VALIDATE="$SCRIPT_DIR/../scripts/validate-reconcile-batch.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

for s in "$BUILD" "$VALIDATE"; do
  [ -x "$s" ] || fail "script missing or not executable: $s"
done

TMPROOT=$(mktemp -d "/tmp/dream-reconcile-batch-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

VAULT_ME="$TMPROOT/me"
VAULT_PROJECTS="$TMPROOT/projects"
mkdir -p "$VAULT_ME/wiki/skills" "$VAULT_PROJECTS/wiki"

cat > "$VAULT_ME/wiki/bio.md" <<'MD'
# Bio

## Bio

- lives in Berlin
MD

cat > "$VAULT_ME/wiki/skills/deep-learning.md" <<'MD'
# Deep Learning

## Deep Learning

- knows PyTorch
MD

cat > "$VAULT_PROJECTS/wiki/aximon.md" <<'MD'
# Aximon

## Architecture

- auth currently uses JWT
MD

CONFIG="$TMPROOT/config.toml"
cat > "$CONFIG" <<TOML
reports_dir = "$TMPROOT/reports"

[vaults.me]
root = "$VAULT_ME"
description = "Identity and skills"

[vaults.projects]
root = "$VAULT_PROJECTS"
description = "Project pages"
TOML

ROUTED="$TMPROOT/routed.json"
cat > "$ROUTED" <<'JSON'
[
  {
    "candidate_id": "c000001",
    "candidate": {"content":"lives in Munich","confidence":"high","source_chat":"a.jsonl","source_date":"2026-06-01","suggested_section":"Bio"},
    "route": {"status":"routed","vault":"me","page":"wiki/bio.md","section":"Bio","routing_confidence":"high"}
  },
  {
    "candidate_id": "c000002",
    "candidate": {"content":"originally from Kyiv","confidence":"high","source_chat":"b.jsonl","source_date":"2026-06-02","suggested_section":"Bio"},
    "route": {"status":"routed","vault":"me","page":"wiki/bio.md","section":"Bio","routing_confidence":"high"}
  },
  {
    "candidate_id": "c000003",
    "candidate": {"content":"uses PyTorch Lightning","confidence":"medium","source_chat":"c.jsonl","source_date":"2026-06-03","suggested_section":"Deep Learning"},
    "route": {"status":"routed","vault":"me","page":"wiki/skills/deep-learning.md","section":"Deep Learning","routing_confidence":"high"}
  },
  {
    "candidate_id": "c000006",
    "candidate": {"content":"uses Lightning callbacks","confidence":"high","source_chat":"f.jsonl","source_date":"2026-06-04","suggested_section":"Frameworks"},
    "route": {"status":"routed","vault":"me","page":"wiki/skills/deep-learning.md","section":"Frameworks","routing_confidence":"high"}
  },
  {
    "candidate_id": "c000004",
    "candidate": {"content":"switched aximon auth to sessions","confidence":"high","source_chat":"d.jsonl","source_date":"2026-06-04","suggested_section":"Architecture"},
    "route": {"status":"routed","vault":"projects","page":"wiki/aximon.md","section":"Architecture","routing_confidence":"high"}
  },
  {
    "candidate_id": "c000005",
    "candidate": {"content":"unroutable fact","confidence":"low","source_chat":"e.jsonl","source_date":"2026-06-04"},
    "route": {"status":"gap","vault":null,"page":null,"section":null,"routing_confidence":"low"}
  }
]
JSON

BATCHES="$TMPROOT/reconcile-batches.json"
"$BUILD" --config "$CONFIG" --run-date 2026-06-04 --max-candidates 2 < "$ROUTED" > "$BATCHES"

[ "$(jq 'length' "$BATCHES")" = "3" ] || fail "expected 3 reconcile batches; gap records should be ignored"
[ "$(jq -r '.[0].batch_id' "$BATCHES")" = "reconcile-0001" ] || fail "wrong first reconcile batch id"
[ "$(jq -r '.[0].target.page' "$BATCHES")" = "wiki/bio.md" ] || fail "first group should target bio page"
[ "$(jq '.[0].candidates | length' "$BATCHES")" = "2" ] || fail "bio candidates should be grouped together"
[ "$(jq -r '.[1].target.page' "$BATCHES")" = "wiki/skills/deep-learning.md" ] \
  || fail "second group should target deep-learning page"
[ "$(jq '.[1].candidates | length' "$BATCHES")" = "2" ] \
  || fail "deep-learning candidates from different sections should share one page batch"
[ "$(jq -r '.[1].candidates[1].route.section' "$BATCHES")" = "Frameworks" ] \
  || fail "candidate-level routed section was not preserved"
[ "$(jq -r '.[0].target_page' "$BATCHES" | grep -c 'lives in Berlin')" = "1" ] \
  || fail "target page snapshot missing expected page content"
[ "$(jq '[.[].candidates[].candidate_id] | index("c000005") == null' "$BATCHES")" = "true" ] \
  || fail "gap candidate leaked into reconcile batches"
echo "PASS: build-reconcile-batches groups by target page and skips non-routed records"

BATCH1="$TMPROOT/reconcile-batch-1.json"
jq '.[0]' "$BATCHES" > "$BATCH1"

DECISIONS="$TMPROOT/reconcile-decisions.json"
cat > "$DECISIONS" <<'JSON'
[
  {
    "candidate_id":"c000001",
    "action":"supersede",
    "mode":"replace",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "old_content":"lives in Berlin",
    "content":"lives in Munich",
    "candidate_confidence":"high",
    "needs_review":true,
    "rationale":"Candidate is newer than existing location."
  },
  {
    "candidate_id":"c000002",
    "action":"duplicate",
    "mode":"none",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "content":"",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Equivalent fact already exists, so no write is needed."
  }
]
JSON

VALIDATED=$("$VALIDATE" --batch "$BATCH1" < "$DECISIONS")
[ "$(printf '%s' "$VALIDATED" | jq 'length')" = "2" ] || fail "validated reconcile output should have two decisions"
[ "$(printf '%s' "$VALIDATED" | jq -r '.[0].decision.action')" = "supersede" ] \
  || fail "validated output lost first decision"
echo "PASS: validate-reconcile-batch accepts valid page-grouped decisions"

BATCH2="$TMPROOT/reconcile-batch-2.json"
jq '.[1]' "$BATCHES" > "$BATCH2"

MULTI_SECTION="$TMPROOT/reconcile-multi-section.json"
cat > "$MULTI_SECTION" <<'JSON'
[
  {
    "candidate_id":"c000003",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/skills/deep-learning.md","section":"Deep Learning"},
    "content":"uses PyTorch Lightning",
    "candidate_confidence":"medium",
    "needs_review":true,
    "rationale":"Fact is absent but medium confidence."
  },
  {
    "candidate_id":"c000006",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/skills/deep-learning.md","section":"Frameworks"},
    "content":"uses Lightning callbacks",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Fact is absent and high confidence."
  }
]
JSON
"$VALIDATE" --batch "$BATCH2" < "$MULTI_SECTION" >/dev/null \
  || fail "validator rejected valid same-page, different-section decisions"
echo "PASS: validate-reconcile-batch accepts same-page batches with per-candidate sections"

BAD_SECTION="$TMPROOT/reconcile-bad-section.json"
cat > "$BAD_SECTION" <<'JSON'
[
  {
    "candidate_id":"c000003",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/skills/deep-learning.md","section":"Frameworks"},
    "content":"uses PyTorch Lightning",
    "candidate_confidence":"medium",
    "needs_review":true,
    "rationale":"Wrong section should fail."
  },
  {
    "candidate_id":"c000006",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/skills/deep-learning.md","section":"Frameworks"},
    "content":"uses Lightning callbacks",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Fact is absent."
  }
]
JSON
if "$VALIDATE" --batch "$BATCH2" < "$BAD_SECTION" >/dev/null 2>&1; then
  fail "validator accepted decision with section drift"
fi
echo "PASS: validate-reconcile-batch rejects per-candidate section drift"

TARGET_MISMATCH="$TMPROOT/reconcile-target-mismatch.json"
cat > "$TARGET_MISMATCH" <<'JSON'
[
  {
    "candidate_id":"c000001",
    "action":"new",
    "mode":"append",
    "target":{"vault":"projects","page":"wiki/aximon.md","section":"Architecture"},
    "content":"lives in Munich",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Wrong target should fail."
  },
  {
    "candidate_id":"c000002",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "content":"originally from Kyiv",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Fact is absent."
  }
]
JSON
if "$VALIDATE" --batch "$BATCH1" < "$TARGET_MISMATCH" >/dev/null 2>&1; then
  fail "validator accepted decision with target outside batch page"
fi
echo "PASS: validate-reconcile-batch rejects target mismatch"

BAD_REVIEW_RULE="$TMPROOT/reconcile-bad-review.json"
cat > "$BAD_REVIEW_RULE" <<'JSON'
[
  {
    "candidate_id":"c000001",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "content":"lives in Munich",
    "candidate_confidence":"high",
    "needs_review":true,
    "rationale":"High-confidence new should not need review."
  },
  {
    "candidate_id":"c000002",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "content":"originally from Kyiv",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Fact is absent."
  }
]
JSON
if "$VALIDATE" --batch "$BATCH1" < "$BAD_REVIEW_RULE" >/dev/null 2>&1; then
  fail "validator accepted invalid needs_review rule"
fi
echo "PASS: validate-reconcile-batch rejects invalid needs_review rule"

BAD_CONF="$TMPROOT/reconcile-bad-confidence.json"
cat > "$BAD_CONF" <<'JSON'
[
  {
    "candidate_id":"c000001",
    "action":"supersede",
    "mode":"replace",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "old_content":"lives in Berlin",
    "content":"lives in Munich",
    "candidate_confidence":"medium",
    "needs_review":true,
    "rationale":"Confidence changed should fail."
  },
  {
    "candidate_id":"c000002",
    "action":"new",
    "mode":"append",
    "target":{"vault":"me","page":"wiki/bio.md","section":"Bio"},
    "content":"originally from Kyiv",
    "candidate_confidence":"high",
    "needs_review":false,
    "rationale":"Fact is absent."
  }
]
JSON
if "$VALIDATE" --batch "$BATCH1" < "$BAD_CONF" >/dev/null 2>&1; then
  fail "validator accepted changed candidate_confidence"
fi
echo "PASS: validate-reconcile-batch rejects candidate_confidence drift"

echo "All reconcile batching tests passed."
