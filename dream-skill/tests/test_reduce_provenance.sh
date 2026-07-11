#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cat <<'JSON' | "$SKILL_DIR/scripts/reduce-dedup.py" > /tmp/dream-reduce-provenance-$$.json
[
  {"content":"Possible preference","confidence":"medium","source_chat":"a","source_role":"assistant_context","memory_tier":"stable"},
  {"content":"Possible preference","confidence":"medium","source_chat":"b","source_role":"assistant_context","memory_tier":"stable"},
  {"content":"Possible preference","confidence":"medium","source_chat":"c","source_role":"assistant_context","memory_tier":"stable"},
  {"content":"Direct preference","confidence":"high","source_chat":"d","source_role":"user","memory_tier":"stable"},
  {"content":"Direct preference","confidence":"high","source_chat":"e","source_role":"user","memory_tier":"stable"},
  {"content":"Direct preference","confidence":"high","source_chat":"f","source_role":"user","memory_tier":"stable"},
  {"content":"The user prefers concise practical reports","confidence":"high","source_chat":"g","source_role":"user","memory_tier":"stable"},
  {"content":"The user prefers practical concise reports","confidence":"high","source_chat":"h","source_role":"user","memory_tier":"stable"},
  {"content":"Possible future goal","confidence":"low","source_chat":"i","source_role":"user","memory_tier":"stable"},
  {"content":"Possible future goal","confidence":"low","source_chat":"j","source_role":"user","memory_tier":"stable"},
  {"content":"Possible future goal","confidence":"low","source_chat":"k","source_role":"user","memory_tier":"stable"}
]
JSON
trap 'rm -f /tmp/dream-reduce-provenance-$$.json' EXIT
jq -e '.[] | select(.content == "Possible preference") | .confidence == "medium"' /tmp/dream-reduce-provenance-$$.json >/dev/null
jq -e '.[] | select(.content == "Direct preference") | .confidence == "high"' /tmp/dream-reduce-provenance-$$.json >/dev/null
jq -e '[.[] | select(.content | contains("concise"))] | length == 1' /tmp/dream-reduce-provenance-$$.json >/dev/null
jq -e '.[] | select(.content == "Possible future goal") | .confidence == "low"' /tmp/dream-reduce-provenance-$$.json >/dev/null

echo "test_reduce_provenance: ok"
