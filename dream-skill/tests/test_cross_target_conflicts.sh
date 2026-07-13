#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$SKILL_DIR/scripts/gate-cross-target-conflicts.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/input.json" <<'JSON'
[
  {"candidate_id":"a","decision":{"action":"new","needs_review":false,"target":{"vault":"clinic","page":"wiki/classifier.md","section":"Work"},"content":"The Cleveland Clinic US address classifier needs structured and unstructured validation."}},
  {"candidate_id":"b","decision":{"action":"new","needs_review":false,"target":{"vault":"me","page":"wiki/manual.md","section":"Work"},"content":"US address classifier validation at Cleveland Clinic covers structured and unstructured data."}},
  {"candidate_id":"c","decision":{"action":"new","needs_review":false,"target":{"vault":"clinic","page":"wiki/classifier.md","section":"Work"},"content":"The Cleveland Clinic classifier also needs a synthetic fixture."}},
  {"candidate_id":"d","decision":{"action":"duplicate","needs_review":false,"target":{"vault":"me","page":"wiki/manual.md","section":"Work"},"content":"US address classifier validation at Cleveland Clinic covers structured and unstructured data."}}
]
JSON
"$GATE" --report < "$TMP/input.json" > "$TMP/output.json" 2> "$TMP/report.txt"
jq -e '.[0].decision.cross_target_review == true and .[0].decision.cross_target_candidate_ids == ["b"]' "$TMP/output.json" >/dev/null
jq -e '.[1].decision.cross_target_review == true and .[1].decision.cross_target_candidate_ids == ["a"]' "$TMP/output.json" >/dev/null
jq -e '.[2].decision.needs_review == false and (.[2].decision.cross_target_review // false) == false' "$TMP/output.json" >/dev/null
jq -e '.[3].decision.action == "duplicate" and (.[3].decision.cross_target_review // false) == false' "$TMP/output.json" >/dev/null
grep -q '^gate-cross-target-conflicts: in=4 gated=2 pairs=1 threshold=0.52$' "$TMP/report.txt"
echo "test_cross_target_conflicts: ok"
