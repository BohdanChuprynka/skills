#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$SKILL_DIR/scripts/classify-candidate-policy.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rg -q 'Make every project or work fact self-contained' "$SKILL_DIR/prompts/map.md"

cat > "$TMP/input.json" <<'JSON'
[
  {"content":"Bohdan prefers one connector per worktree as a standing workflow.","type":"workflow preference","memory_tier":"stable"},
  {"content":"Bohdan is currently testing the connector through a local development server.","type":"active work","memory_tier":"current"},
  {"content":"PR #86 must remain unmerged until review finishes.","type":"project status","memory_tier":"current"},
  {"content":"The security architecture verifies webhook signatures before processing.","type":"architecture decision","memory_tier":"stable"},
  {"content":"Bohdan has a meeting at 4 PM on July 20.","type":"schedule","memory_tier":"current"},
  {"content":"The test suite passed 6/6 checks.","type":"test receipt","memory_tier":"stable"},
  {"content":"The user asked to implement the approved plan now.","type":"execution plan","memory_tier":"current"},
  {"content":"The implementation had to avoid introducing a shared adapter.","type":"architecture","memory_tier":"stable"},
  {"content":"Google Calendar was added on branch feat/google-calendar-live-connector.","type":"project decision","memory_tier":"stable"},
  {"content":"Remly uses connector-specific schemas for each provider.","type":"architecture","memory_tier":"stable"},
  {"content":"The latest source state has a finished plan with execution intended to start at Task 0.","type":"project state","memory_tier":"current"},
  {"content":"The browser test set had five scenarios detected but not run because no target was configured.","type":"testing","memory_tier":"current"},
  {"content":"The assistant described V2 as a shared live-retrieval platform.","type":"architecture","memory_tier":"stable"}
]
JSON

"$POLICY" --report < "$TMP/input.json" > "$TMP/output.json" 2> "$TMP/report.txt"
jq -e 'length == 13' "$TMP/output.json" >/dev/null
jq -e '.[0].fact_class == "preference" and (.[0].policy_review_only // false) == false' "$TMP/output.json" >/dev/null
jq -e '.[1].fact_class == "active_state" and .[1].policy_review_only == true and (. [1].policy_reasons | index("temporary_implementation")) != null' "$TMP/output.json" >/dev/null
jq -e '.[2].policy_review_only == true and (. [2].policy_reasons | index("pull_request_state")) != null' "$TMP/output.json" >/dev/null
jq -e '.[3].fact_class == "project_decision" and (.[3].policy_review_only // false) == false' "$TMP/output.json" >/dev/null
jq -e '.[4].fact_class == "schedule" and (.[4].policy_review_only // false) == false' "$TMP/output.json" >/dev/null
jq -e '.[5].fact_class == "audit_telemetry" and .[5].policy_review_only == true' "$TMP/output.json" >/dev/null
jq -e '.[6].policy_review_only == true and (.[6].policy_reasons | index("event_narration")) != null' "$TMP/output.json" >/dev/null
jq -e '.[7].policy_review_only == true and (.[7].policy_reasons | index("generic_owner")) != null' "$TMP/output.json" >/dev/null
jq -e '.[8].policy_review_only == true and (.[8].policy_reasons | index("execution_detail")) != null' "$TMP/output.json" >/dev/null
jq -e '(.[9].policy_review_only // false) == false' "$TMP/output.json" >/dev/null
jq -e '.[10].policy_review_only == true and (.[10].policy_reasons | index("transient_context")) != null' "$TMP/output.json" >/dev/null
jq -e '.[11].policy_review_only == true and (.[11].policy_reasons | index("test_receipt")) != null' "$TMP/output.json" >/dev/null
jq -e '.[12].policy_review_only == true and (.[12].policy_reasons | index("assistant_narration")) != null' "$TMP/output.json" >/dev/null
grep -q '^classify-candidate-policy: in=13 review_only=9 classes=' "$TMP/report.txt"

if printf 'not an array' | "$POLICY" >/dev/null 2>&1; then
  echo "candidate policy accepted invalid JSON" >&2
  exit 1
fi

echo "test_candidate_policy: ok"
