#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/me/wiki" "$TMP/projects/wiki"
cat > "$TMP/me/wiki/People.md" <<'MD'
# People

## Mentors and friends

- Alice is a mentor.
MD
cat > "$TMP/projects/wiki/sample-project.md" <<'MD'
# Sample Project

## Architecture

- Local retrieval architecture.
MD
cat > "$TMP/config.toml" <<EOF
[vaults.me]
root = "$TMP/me"
description = "Identity, relationships, mentors, friends"

[vaults.projects]
root = "$TMP/projects"
description = "Project architecture and codebases"
EOF

cat > "$TMP/candidates.json" <<'JSON'
[
  {"content":"Avery is the user's mentor.","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"},
  {"content":"Sample Project uses a local retrieval architecture.","confidence":"high","source_chat":"b","source_date":"2026-07-01","memory_tier":"stable"}
]
JSON

"$SCRIPTS/build-route-batches.py" --config "$TMP/config.toml" --top-k 1 \
  < "$TMP/candidates.json" > "$TMP/batches.json"
jq '.[0]' "$TMP/batches.json" > "$TMP/batch.json"

people_id=$(jq -r '.candidates[0].candidate_id' "$TMP/batch.json")
project_id=$(jq -r '.candidates[1].candidate_id' "$TMP/batch.json")
people_allowed=$(jq -r '.candidates[0].allowed_page_ids[0]' "$TMP/batch.json")
project_allowed=$(jq -r '.candidates[1].allowed_page_ids[0]' "$TMP/batch.json")
[ "$(jq -r --arg id "$people_allowed" '.page_catalog[] | select(.page_id==$id) | .page' "$TMP/batch.json")" = "wiki/People.md" ]
[ "$(jq -r --arg id "$project_allowed" '.page_catalog[] | select(.page_id==$id) | .page' "$TMP/batch.json")" = "wiki/sample-project.md" ]

# The first route intentionally selects a canonical page outside its retrieved
# allow-list. Validation must turn it into a gap.
jq -n --arg p "$people_id" --arg r "$project_id" '[
  {candidate_id:$p,status:"routed",vault:"projects",page:"wiki/sample-project.md",section:"Architecture",routing_confidence:"medium"},
  {candidate_id:$r,status:"routed",vault:"projects",page:"wiki/sample-project.md",section:"Architecture",routing_confidence:"high"}
]' > "$TMP/routes.json"

"$SCRIPTS/validate-route-batch.py" --batch "$TMP/batch.json" --config "$TMP/config.toml" \
  --missing-page-policy gap < "$TMP/routes.json" > "$TMP/validated.json"
jq -e --arg id "$people_id" '.[] | select(.candidate_id==$id) | .route.status == "gap"' "$TMP/validated.json" >/dev/null
jq -e --arg id "$project_id" '.[] | select(.candidate_id==$id) | .route.status == "routed"' "$TMP/validated.json" >/dev/null

for index in $(seq -w 1 40); do
  printf '# General %s\n\n## Context\n\nGeneral context %s.\n' "$index" "$index" \
    > "$TMP/projects/wiki/general-$index.md"
done
cat > "$TMP/general-candidate.json" <<'JSON'
[{"content":"The user tracks general context.","confidence":"high","source_chat":"c","source_date":"2026-07-01","memory_tier":"stable"}]
JSON
"$SCRIPTS/build-route-batches.py" --config "$TMP/config.toml" \
  < "$TMP/general-candidate.json" > "$TMP/default-top-k.json"
[ "$(jq '.[0].candidates[0].allowed_page_ids | length' "$TMP/default-top-k.json")" = "32" ]

echo "test_route_retrieval: ok"
