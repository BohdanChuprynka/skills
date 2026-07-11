#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$SKILL_DIR/scripts/validate-candidates.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/unit.txt" <<'TXT'
USER[1]: I prefer concise reports.
ASST[2]: You prefer detailed reports.
USER[3]: Maybe, but I am not deciding that yet.
TXT

cat > "$TMP/candidates.json" <<'JSON'
[
  {"content":"The user prefers concise reports.","confidence":"high","source_chat":"chat-a","source_date":"2026-07-01","source_role":"user","source_event":1,"evidence":"I prefer concise reports.","type":"preference","memory_tier":"stable"},
  {"content":"The user prefers detailed reports.","confidence":"high","source_chat":"chat-a","source_date":"2026-07-01","source_role":"assistant_context","source_event":2,"evidence":"You prefer detailed reports.","memory_tier":"stable"},
  {"content":"- Pre-bulleted fact","confidence":"medium","source_chat":"chat-a","source_date":"2026-07-01","source_role":"user_confirmation","source_event":3,"evidence":"Maybe","memory_tier":"stable"},
  {"content":"Invented evidence","confidence":"medium","source_chat":"chat-a","source_date":"2026-07-01","source_role":"user","source_event":1,"evidence":"not in source","memory_tier":"stable"}
]
JSON

"$VALIDATOR" --unit "$TMP/unit.txt" --source-chat chat-a < "$TMP/candidates.json" > "$TMP/valid.json"
[ "$(jq 'length' "$TMP/valid.json")" = "1" ]
jq -e '.[0].source_role == "user" and .[0].source_event == 1' "$TMP/valid.json" >/dev/null

if printf '{}' | "$VALIDATOR" >/dev/null 2>&1; then
  echo "non-array MAP output unexpectedly accepted" >&2
  exit 1
fi

content_320="$(printf '%*s' 320 '' | tr ' ' x)"
content_321="${content_320}x"

jq -n --arg content "$content_320" '[{
  content: $content,
  confidence: "high",
  source_chat: "chat-boundary",
  source_date: "2026-07-01",
  source_role: "user",
  source_event: 1,
  evidence: "x",
  memory_tier: "stable"
}]' | "$VALIDATOR" > "$TMP/boundary-320.json"
[ "$(jq 'length' "$TMP/boundary-320.json")" = "1" ]

jq -n --arg content "$content_321" '[{
  content: $content,
  confidence: "high",
  source_chat: "chat-boundary",
  source_date: "2026-07-01",
  source_role: "user",
  source_event: 1,
  evidence: "x",
  memory_tier: "stable"
}]' | "$VALIDATOR" > "$TMP/boundary-321.json"
[ "$(jq 'length' "$TMP/boundary-321.json")" = "0" ]

echo "test_candidate_validation: ok"
