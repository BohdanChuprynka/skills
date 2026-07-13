#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$SKILL_DIR/scripts/gate-write-density.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/vault/wiki"
{
  echo '---'
  echo 'updated: 2026-01-01'
  echo '---'
  echo '# Large'
  for i in $(seq 1 8); do echo "line $i"; done
} > "$TMP/vault/wiki/large.md"
cat > "$TMP/vault/wiki/small.md" <<'MD'
# Small
MD
cat > "$TMP/config.toml" <<EOF
[vaults.projects]
root = "$TMP/vault"
description = "Projects"
EOF
cat > "$TMP/input.json" <<'JSON'
[
  {"candidate_id":"a","decision":{"action":"new","needs_review":false,"target":{"vault":"projects","page":"wiki/small.md","section":"A"},"content":"one"}},
  {"candidate_id":"b","decision":{"action":"new","needs_review":false,"target":{"vault":"projects","page":"wiki/small.md","section":"A"},"content":"two"}},
  {"candidate_id":"c","decision":{"action":"new","needs_review":false,"target":{"vault":"projects","page":"wiki/small.md","section":"B"},"content":"three"}},
  {"candidate_id":"d","decision":{"action":"new","needs_review":false,"target":{"vault":"projects","page":"wiki/large.md","section":"A"},"content":"large"}},
  {"candidate_id":"e","decision":{"action":"duplicate","needs_review":false,"target":{"vault":"projects","page":"wiki/large.md","section":"A"},"content":""}}
]
JSON

"$GATE" --config "$TMP/config.toml" --page-limit 2 --section-limit 1 --page-line-threshold 10 --report \
  < "$TMP/input.json" > "$TMP/output.json" 2> "$TMP/report.txt"
jq -e '.[0].decision.needs_review == false' "$TMP/output.json" >/dev/null
jq -e '.[1].decision.needs_review == true and (.[1].decision.density_reasons | index("run_section_limit")) != null' "$TMP/output.json" >/dev/null
jq -e '.[2].decision.needs_review == true and (.[2].decision.density_reasons | index("run_page_limit")) != null' "$TMP/output.json" >/dev/null
jq -e '.[3].decision.needs_review == true and .[3].decision.target_page_lines >= 10 and (.[3].decision.density_reasons | index("existing_page_too_large")) != null' "$TMP/output.json" >/dev/null
jq -e '.[4].decision.action == "duplicate" and (.[4].decision.density_review // false) == false' "$TMP/output.json" >/dev/null
grep -q '^gate-write-density: in=5 gated=3 reasons=' "$TMP/report.txt"

echo "test_write_density: ok"
