#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER="$SKILL_DIR/scripts/build-route-batches.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' '[
  {"content":"Alpha","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"},
  {"content":"Beta","confidence":"medium","source_chat":"b","source_date":"2026-07-02","memory_tier":"stable"}
]' | "$BUILDER" > "$TMP/one.json"

printf '%s\n' '[
  {"content":"Beta","confidence":"medium","source_chat":"b","source_date":"2026-07-02","memory_tier":"stable"},
  {"content":"Alpha","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"}
]' | "$BUILDER" > "$TMP/two.json"

jq -S '[.[].candidates[] | {content:.candidate.content,id:.candidate_id}] | sort_by(.content)' "$TMP/one.json" > "$TMP/one-ids.json"
jq -S '[.[].candidates[] | {content:.candidate.content,id:.candidate_id}] | sort_by(.content)' "$TMP/two.json" > "$TMP/two-ids.json"
cmp "$TMP/one-ids.json" "$TMP/two-ids.json"
jq -e 'all(.[].id; test("^c-[0-9a-f]{20}$"))' "$TMP/one-ids.json" >/dev/null

# Review gates may add mutable age/sample fields and lower confidence.  Those
# policy annotations must not change the queue/sidecar identity across retries.
printf '%s\n' '[
  {"content":"Gamma","confidence":"high","source_chat":"c","source_date":"2026-05-01","memory_tier":"current"}
]' | "$BUILDER" > "$TMP/base-policy.json"
printf '%s\n' '[
  {"content":"Gamma","confidence":"medium","original_confidence":"high","source_chat":"c","source_date":"2026-05-01","memory_tier":"current","historical_review":true,"historical_age_days":72,"quality_review_sample":true,"quality_review_bucket":4}
]' | "$BUILDER" > "$TMP/gated-policy.json"
[ "$(jq -r '.[0].candidates[0].candidate_id' "$TMP/base-policy.json")" = \
  "$(jq -r '.[0].candidates[0].candidate_id' "$TMP/gated-policy.json")" ]

printf '%s\n' '[
  {"content":"Gamma","confidence":"medium","original_confidence":"high","source_chat":"c","source_date":"2026-05-01","memory_tier":"current","historical_review":true,"historical_age_days":73}
]' | "$BUILDER" > "$TMP/next-day-policy.json"
[ "$(jq -r '.[0].candidates[0].candidate_id' "$TMP/base-policy.json")" = \
  "$(jq -r '.[0].candidates[0].candidate_id' "$TMP/next-day-policy.json")" ]

if printf '%s\n' '[
  {"content":"Alpha","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"},
  {"content":"Alpha","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"}
]' | "$BUILDER" >/dev/null 2>&1; then
  echo "duplicate stable candidates unexpectedly accepted" >&2
  exit 1
fi

echo "test_stable_ids: ok"
