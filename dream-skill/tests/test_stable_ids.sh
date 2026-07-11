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

if printf '%s\n' '[
  {"content":"Alpha","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"},
  {"content":"Alpha","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"}
]' | "$BUILDER" >/dev/null 2>&1; then
  echo "duplicate stable candidates unexpectedly accepted" >&2
  exit 1
fi

echo "test_stable_ids: ok"
