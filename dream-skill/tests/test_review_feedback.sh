#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/review.json" <<'JSON'
{"entries":[
  {"id":"a","vault":"projects","candidate_type":"task_request","fact_class":"active_state","memory_tier":"current","historical_review":true,"quality_review_sample":true,"run_id":"run-week-1","context":"private candidate text"},
  {"id":"b","vault":"me","candidate_type":"preference","fact_class":"preference","memory_tier":"stable","historical_review":false,"quality_review_sample":false,"run_id":"run-week-1","context":"another private fact"},
  {"id":"c","vault":"projects","candidate_type":"decision","fact_class":"project_decision","memory_tier":"stable","historical_review":false,"quality_review_sample":false,"run_id":"run-week-2","context":"third private fact"}
]}
JSON
cat > "$TMP/decisions.json" <<'JSON'
{"a":"reject","b":"approve","c":"reject"}
JSON
cat > "$TMP/feedback.json" <<'JSON'
{
  "a":{"decision":"reject","reason":"not_durable","recorded_at":"2026-07-12T00:00:00Z"},
  "b":{"decision":"approve","reason":"accepted","recorded_at":"2026-07-12T00:00:00Z"},
  "c":{"decision":"reject","reason":"wrong_target","recorded_at":"2026-07-12T00:00:00Z"}
}
JSON

"$SKILL_DIR/scripts/summarize-review-feedback.py" \
  --review-input "$TMP/review.json" --decisions "$TMP/decisions.json" \
  --feedback "$TMP/feedback.json" --output "$TMP/summary.json" >/dev/null

jq -e '.reviewed == 3 and .outcomes.approve == 1 and .outcomes.reject == 2' "$TMP/summary.json" >/dev/null
jq -e '.rejection_reasons.not_durable == 1 and .rejection_reasons.wrong_target == 1' "$TMP/summary.json" >/dev/null
jq -e '.historical_review_outcomes.reject == 1 and .derived.reject_reason_coverage == 1' "$TMP/summary.json" >/dev/null
jq -e '.quality_review_sample_outcomes.reject == 1 and .derived.quality_sample_reject_rate == 1' "$TMP/summary.json" >/dev/null
jq -e '.outcomes_by_run_id."run-week-1".approve == 1 and .outcomes_by_run_id."run-week-1".reject == 1 and .outcomes_by_run_id."run-week-2".reject == 1' "$TMP/summary.json" >/dev/null
jq -e '.schema_version == 2 and .outcomes_by_fact_class.active_state.reject == 1 and .outcomes_by_memory_tier.stable.approve == 1' "$TMP/summary.json" >/dev/null
jq -e '.groups.fact_class.active_state.reviewed == 1 and .groups.fact_class.active_state.rejection_reasons.not_durable == 1 and .groups.fact_class.active_state.reject_rate == 1' "$TMP/summary.json" >/dev/null
jq -e '.groups.memory_tier.current.outcomes.reject == 1 and .groups.quality_review_sample.sample.outcomes.reject == 1 and .groups.quality_review_sample.not_sample.reviewed == 2' "$TMP/summary.json" >/dev/null
jq -e '.groups.historical_review.historical.rejection_reasons.not_durable == 1 and .groups.vault.projects.rejection_reasons.wrong_target == 1 and .groups.run_id."run-week-1".reviewed == 2' "$TMP/summary.json" >/dev/null
jq -e '.improvement_signals | length == 2' "$TMP/summary.json" >/dev/null
! rg -q 'private candidate text|another private fact|third private fact|"a"|"b"|"c"' "$TMP/summary.json"
[ "$(stat -f '%Lp' "$TMP/summary.json" 2>/dev/null || stat -c '%a' "$TMP/summary.json")" = "600" ]

echo "test_review_feedback: ok"
