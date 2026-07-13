#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/me/wiki" "$TMP/projects/wiki"
mkdir -p "$TMP/projects/wiki/_archive" "$TMP/projects/wiki/archive" \
  "$TMP/projects/wiki/raw" "$TMP/projects/wiki/logs" "$TMP/projects/wiki/excluded"
mkdir -p "$TMP/notes/Notes" "$TMP/notes/Categories" "$TMP/notes/Templates"
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
cat > "$TMP/projects/wiki/exact-canonical.md" <<'MD'
# Exact Canonical

This introductory synopsis distinguishes durable routing ownership.

## Architecture

- Durable facts live here.
MD
cat > "$TMP/projects/wiki/body-polluted.md" <<'MD'
# Generic Notes

## Facts

- Exact Canonical Exact Canonical Exact Canonical Exact Canonical.
- Exact Canonical Exact Canonical Exact Canonical Exact Canonical.
MD
printf '# Archived copy\n' > "$TMP/projects/wiki/_archive/exact-canonical.md"
printf '# Archived copy\n' > "$TMP/projects/wiki/archive/another-copy.md"
printf '# Raw capture\n' > "$TMP/projects/wiki/raw/capture.md"
printf '# Daily log\n' > "$TMP/projects/wiki/logs/2026-07-01.md"
printf '# Session Log\n' > "$TMP/projects/wiki/session-log.md"
cat > "$TMP/projects/wiki/completed-project.md" <<'MD'
---
status: completed
---
# Completed Project
MD
cat > "$TMP/projects/wiki/archived-project.md" <<'MD'
---
status: "archived" # historical only
---
# Archived Project
MD
printf '# Explicitly excluded\n' > "$TMP/projects/wiki/excluded/secret.md"
cat > "$TMP/notes/Notes/Microeconomics Review.md" <<'MD'
# Microeconomics Review

## Exam prep
MD
printf '# IT\n' > "$TMP/notes/Categories/IT.md"
printf '# Unsafe template\n' > "$TMP/notes/Templates/Unsafe.md"
cat > "$TMP/config.toml" <<EOF
[vaults.me]
root = "$TMP/me"
description = "Identity, relationships, mentors, friends"

[vaults.projects]
root = "$TMP/projects"
description = "Project architecture and codebases"
route_include = ["wiki"]
route_exclude = ["wiki/excluded"]

[vaults.notes]
root = "$TMP/notes"
description = "School subjects and exam prep"
review_only = true
route_include = ["Notes", "References"]
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

# Non-wiki vault policy exposes only explicit writable/reviewable areas.  A
# short page stem such as IT must not receive a substring boost from "with".
cat > "$TMP/micro-candidate.json" <<'JSON'
[{"content":"The user is preparing an AP Microeconomics cheat sheet with market structures.","confidence":"high","source_chat":"d","source_date":"2026-07-01","memory_tier":"stable"}]
JSON
"$SCRIPTS/build-route-batches.py" --config "$TMP/config.toml" --top-k 8 \
  < "$TMP/micro-candidate.json" > "$TMP/micro-batches.json"
jq -e '[.[0].page_catalog[].page] | index("Notes/Microeconomics Review.md") != null' "$TMP/micro-batches.json" >/dev/null
jq -e '[.[0].page_catalog[].page] | index("Categories/IT.md") == null and index("Templates/Unsafe.md") == null' "$TMP/micro-batches.json" >/dev/null

# Default canonical guards remove archive/raw/log surfaces and inactive pages,
# while explicit include/exclude policies continue to bound the eligible tree.
python3 - "$SCRIPTS" "$TMP/config.toml" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from vault_search import build_page_docs, default_route_exclusion_reason

docs = build_page_docs(Path(sys.argv[2]))
project_pages = {doc.page for doc in docs if doc.vault == "projects"}
assert "wiki/sample-project.md" in project_pages
assert "wiki/exact-canonical.md" in project_pages
assert "wiki/_archive/exact-canonical.md" not in project_pages
assert "wiki/archive/another-copy.md" not in project_pages
assert "wiki/raw/capture.md" not in project_pages
assert "wiki/logs/2026-07-01.md" not in project_pages
assert "wiki/session-log.md" not in project_pages
assert "wiki/completed-project.md" not in project_pages
assert "wiki/archived-project.md" not in project_pages
assert "wiki/excluded/secret.md" not in project_pages
assert default_route_exclusion_reason("wiki/_archive/page.md", "") == "noncanonical directory: _archive"
assert default_route_exclusion_reason("wiki/daily-log.md", "") == "noncanonical page type: log"
assert default_route_exclusion_reason("wiki/current.md", "completed") == "frontmatter status: completed"
PY

# Exact page names remain the strongest signal. Repeated facts below an H2 on
# another page must not contaminate retrieval and steal the canonical match.
cat > "$TMP/exact-candidate.json" <<'JSON'
[{"content":"Exact Canonical defines the project architecture.","confidence":"high","source_chat":"e","source_date":"2026-07-01","memory_tier":"stable"}]
JSON
"$SCRIPTS/build-route-batches.py" --config "$TMP/config.toml" --top-k 1 \
  < "$TMP/exact-candidate.json" > "$TMP/exact-batches.json"
[ "$(jq -r '.[0].page_catalog[0].page' "$TMP/exact-batches.json")" = "wiki/exact-canonical.md" ]

python3 - "$SCRIPTS" "$TMP/config.toml" "$TMP/policy-home" <<'PY'
import importlib.util
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("dream_run", scripts / "dream-run.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
policies = module.load_vault_policies(Path(sys.argv[2]))
new = module.enforce_vault_policy({"action": "new", "needs_review": False}, "notes", policies)
duplicate = module.enforce_vault_policy({"action": "duplicate", "needs_review": False}, "notes", policies)
assert new["needs_review"] is True and new["vault_policy_review_only"] is True
assert duplicate == {"action": "duplicate", "needs_review": False}

home = Path(sys.argv[3])
item = {
    "candidate_id": "c-person",
    "candidate": {
        "content": "Taylor Park is a collaborator.",
        "source_chat": "chat",
        "source_date": "2026-07-01",
        "confidence": "high",
    },
    "detected_names": ["Taylor Park"],
}
module.persist_people_review_queue(home, [item])
module.persist_people_review_queue(home, [item])
text = (home / "people-review-queue.md").read_text()
assert text.count("**Candidate ID:** c-person") == 1
PY

echo "test_route_retrieval: ok"
