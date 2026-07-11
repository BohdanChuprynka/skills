#!/usr/bin/env bash
# test_reduce_dedup.sh — REDUCE de-dup (exact + conservative TF-IDF near-dup).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEDUP="$(dirname "$HERE")/scripts/reduce-dedup.py"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
no()  { echo "FAIL: $1"; fail=$((fail+1)); }

[ -x "$DEDUP" ] || { echo "FAIL: reduce-dedup.py not executable"; exit 1; }

# 1) exact (content, section) collapse + confidence promotion across 2 chats
out=$(printf '%s' '[
 {"content":"knows Python","confidence":"low","source_chat":"A","source_date":"2026-06-13","suggested_section":"Skills","memory_tier":"stable"},
 {"content":"knows Python","confidence":"low","source_chat":"B","source_date":"2026-06-13","suggested_section":"Skills","memory_tier":"stable"}
]' | "$DEDUP")
n=$(printf '%s' "$out" | jq length); c=$(printf '%s' "$out" | jq -r '.[0].confidence'); sc=$(printf '%s' "$out" | jq -r '.[0].source_chat_count')
{ [ "$n" = 1 ] && [ "$c" = medium ] && [ "$sc" = 2 ]; } && ok "exact dup collapses, 2 chats -> medium, source_chat_count=2" || no "exact dup ($n,$c,$sc)"

# 2) near-verbatim restatement merges at default threshold.
#    The near-dup layer needs scikit-learn; reduce-dedup.py falls back to exact-only
#    without it (a run is never blocked). CI installs only jq, not sklearn, so this
#    assertion is gated on sklearn being importable — otherwise it is skipped, matching
#    the script's documented graceful-degradation contract.
if python3 -c "import sklearn" >/dev/null 2>&1; then
  out=$(printf '%s' '[
   {"content":"The user switched their primary editor from one tool to another","confidence":"high","source_chat":"A","source_date":"2026-06-13","memory_tier":"stable"},
   {"content":"The user switched their primary editor from one tool to another recently","confidence":"medium","source_chat":"B","source_date":"2026-06-13","memory_tier":"stable"}
  ]' | "$DEDUP")
  [ "$(printf '%s' "$out" | jq length)" = 1 ] && ok "near-verbatim restatement merges (sklearn)" || no "near-dup did not merge ($(printf '%s' "$out" | jq length))"
else
  echo "SKIP: near-dup merge — scikit-learn not installed (reduce-dedup falls back to exact-only)"
fi

# 3) distinct facts about the same subject are PRESERVED (no false merge)
out=$(printf '%s' '[
 {"content":"Persona-RAG dataset has 10238 training examples","confidence":"high","source_chat":"A","source_date":"2026-06-13","memory_tier":"stable"},
 {"content":"Persona-RAG Arm B result Cliff delta 0.949 decisive LoRA win","confidence":"high","source_chat":"A","source_date":"2026-06-13","memory_tier":"stable"}
]' | "$DEDUP")
[ "$(printf '%s' "$out" | jq length)" = 2 ] && ok "distinct same-subject facts preserved" || no "false merge of distinct facts"

# 4) every output carries source_chat_count and required fields
out=$(printf '%s' '[{"content":"x","confidence":"high","source_chat":"A","source_date":"2026-06-13","memory_tier":"stable"}]' | "$DEDUP")
printf '%s' "$out" | jq -e '.[0]|has("source_chat_count") and has("content") and has("confidence") and has("source_chat") and has("source_date")' >/dev/null \
  && ok "output carries source_chat_count + required fields" || no "missing fields in output"

# 5) empty + single input are safe
[ "$(printf '[]' | "$DEDUP" | jq length)" = 0 ] && ok "empty array safe" || no "empty array"
[ "$(printf '%s' '[{"content":"solo","confidence":"low","source_chat":"A","source_date":"2026-06-13","memory_tier":"stable"}]' | "$DEDUP" | jq length)" = 1 ] && ok "single candidate safe" || no "single candidate"

# 6) non-array input errors non-zero
if printf '{}' | "$DEDUP" >/dev/null 2>&1; then no "non-array input should error"; else ok "non-array input errors"; fi

echo "reduce-dedup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
