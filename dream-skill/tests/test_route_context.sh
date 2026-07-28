#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/vault/wiki" "$TMP/chat"

cat > "$TMP/chat/acme.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"cwd":"/work/acme-web","thread_source":"user"}}
JSONL
cat > "$TMP/chat/acme-claude.jsonl" <<'JSONL'
{"type":"attachment","attachment":{"type":"hook_success","cwd":"/work/acme-web"}}
JSONL

cat > "$TMP/vault/wiki/acme.md" <<'MD'
# Acme

## Architecture
MD

cat > "$TMP/vault/wiki/acme-architecture.md" <<'MD'
# Acme Architecture

## Testing Strategy
MD

cat > "$TMP/vault/wiki/local-meeting-scribe-implementation-roadmap.md" <<'MD'
# Local Meeting Scribe Implementation Roadmap

## Testing Strategy
## Architecture Decisions
MD

cat > "$TMP/vault/wiki/Now.md" <<'MD'
# Now

Port 3000 runtime environment testing notes.

## Testing Strategy
MD

cat > "$TMP/config.toml" <<EOF
[vaults.projects]
root = "$TMP/vault"
description = "Repositories and project architecture"

[[routing.workspace_roots]]
path = "/work/acme-web"
project = "acme"
vault = "projects"
aliases = ["acme", "acme-web"]
EOF

python3 "$SCRIPTS/source_context.py" --config "$TMP/config.toml" "$TMP/chat/acme-claude.jsonl" \
  | jq -e '.cwd == "/work/acme-web" and .project == "acme"' >/dev/null

cat > "$TMP/candidates.json" <<JSON
[
  {"content":"The connector needs a final pre-PR testing pass before merge.","confidence":"high","source_chat":"$TMP/chat/acme.jsonl","source_date":"2026-07-12","source_role":"user","source_event":1,"evidence":"final pre-PR testing pass","type":"active_work","suggested_section":"Testing Strategy","memory_tier":"current"},
  {"content":"Can you run port 3000?","confidence":"high","source_chat":"$TMP/chat/acme.jsonl","source_date":"2026-07-12","source_role":"user","source_event":2,"evidence":"run port 3000","type":"environment","suggested_section":"Testing Strategy","memory_tier":"current"}
]
JSON

python3 "$SCRIPTS/build-route-batches.py" --config "$TMP/config.toml" --top-k 8 \
  < "$TMP/candidates.json" > "$TMP/batches.json"

jq -e '. [0].candidates[0].source_context.project == "acme" and
       .[0].candidates[0].source_context.preferred_vault == "projects" and
       .[0].candidates[0].source_context.cwd == "/work/acme-web"' \
  "$TMP/batches.json" >/dev/null

# The generic Meeting Scribe headings must not make that page the first route
# candidate for a fact from a Acme working directory.
jq -e '.[0].page_catalog[0].page == "wiki/acme-architecture.md" or
       .[0].page_catalog[0].page == "wiki/acme.md"' "$TMP/batches.json" >/dev/null

python3 - "$TMP/batches.json" <<'PY'
import json
import sys

batch = json.load(open(sys.argv[1]))[0]
pages = {row["page_id"]: row["page"] for row in batch["page_catalog"]}
for item in batch["candidates"]:
    first = pages[item["allowed_page_ids"][0]]
    assert first in {"wiki/acme.md", "wiki/acme-architecture.md"}, (item, first)
    assert all(pages[page_id] in {"wiki/acme.md", "wiki/acme-architecture.md"}
               for page_id in item["allowed_page_ids"]), item
PY

echo "test_route_context: ok"
