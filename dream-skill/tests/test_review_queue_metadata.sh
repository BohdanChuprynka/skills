#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sidecars"

cat > "$TMP/pending.md" <<'MD'
# Dream queue

### Durable preference
**Bucket:** uncertain
**Confidence:** medium
**ID:** c-modern
**Target:** /vault/me/wiki/Operating Manual.md#Preferences
**Captured:** 2026-07-12T01:02:03Z

> reconciliation explanation from pending

### Legacy fact
**Bucket:** uncertain
**Confidence:** medium
**ID:** c-legacy
**Target:** /vault/projects/wiki/project.md#Overview
**Captured:** 2026-06-01T01:02:03Z

> legacy reconciliation explanation
MD

cat > "$TMP/sidecars/c-modern.json" <<'JSON'
{
  "action":"new",
  "target":{"vault":"me","page":"wiki/Operating Manual.md","section":"Preferences"},
  "content":"The user prefers concise reviews.",
  "rationale":"The candidate is absent from the destination.",
  "source_evidence":"I prefer concise reviews.",
  "candidate_type":"workflow_preference",
  "fact_class":"preference",
  "memory_tier":"stable",
  "source_role":"user",
  "source_date":"2026-07-12",
  "quality_review_sample":true,
  "review_kind":"person_identity",
  "detected_names":["Taylor Park"],
  "run_id":"run-week-1"
}
JSON

cat > "$TMP/sidecars/c-legacy.json" <<'JSON'
{
  "action":"new",
  "target":{"vault":"projects","page":"wiki/project.md","section":"Overview"},
  "content":"A legacy candidate.",
  "rationale":"Legacy cards retained rationale but not exact source evidence."
}
JSON

printf '{"c-legacy":"defer"}\n' > "$TMP/decisions.json"
"$SKILL_DIR/scripts/build-review-queue.py" \
  --pending-md "$TMP/pending.md" --sidecars-dir "$TMP/sidecars" \
  --existing-decisions "$TMP/decisions.json" --output "$TMP/review.json" >/dev/null

jq -e '.schema_version == 2 and (.entries | length) == 2' "$TMP/review.json" >/dev/null
jq -e '.entries[] | select(.id == "c-modern") |
  .fact_class == "preference" and .memory_tier == "stable" and
  .source_evidence == "I prefer concise reviews." and .source_evidence_available == true and
  .context == .source_evidence and
  .reconciliation_rationale == "The candidate is absent from the destination." and
  .diff.note == .reconciliation_rationale and .review_cohort == "run" and .cohort_id == "run-week-1"' "$TMP/review.json" >/dev/null
jq -e '.entries[] | select(.id == "c-modern") |
  .review_kind == "person_identity" and .detected_names == ["Taylor Park"]' "$TMP/review.json" >/dev/null
jq -e '.entries[] | select(.id == "c-legacy") |
  .source_evidence == "" and .source_evidence_available == false and .context == "" and
  .reconciliation_rationale == "Legacy cards retained rationale but not exact source evidence." and
  .fact_class == "other" and .review_cohort == "legacy" and .cohort_id == "legacy" and
  .decided == true and .decision == "defer"' "$TMP/review.json" >/dev/null

HTML="$SKILL_DIR/web/dream-review.html"
! rg -q 'id="filterbar"|id="filterSample"|id="sortOrder"' "$HTML"
rg -Fq 'VIEW_QUEUE = pendingEntries().sort(compareEntries)' "$HTML"
rg -Fq 'grid-template-columns: repeat(4, minmax(0, 1fr))' "$HTML"
rg -q 'class="meta-cell meta-type"' "$HTML"
rg -q 'quality_review_sample' "$HTML"
rg -q 'exact source evidence' "$HTML"
rg -q 'reconciliation rationale' "$HTML"
rg -q 'person identity' "$HTML"
node "$SKILL_DIR/tests/test_review_ui_persistence.mjs" "$HTML"

[ "$(stat -c '%a' "$TMP/review.json" 2>/dev/null || stat -f '%Lp' "$TMP/review.json")" = "600" ]

echo "test_review_queue_metadata: ok"
