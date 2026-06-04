#!/usr/bin/env bash
# Tests the JSON validation harness for MAP subagent output (no model invoked).
# All tests are purely structural — jq validates the 4 required fields.
# No LLM is invoked; no vault is read or written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

# ── validate_candidates harness — source the REAL implementation (M4) ─────────
# Single source of truth: scripts/validate-candidates.sh. Sourcing it (instead of
# re-typing the function) means this test exercises the shipped logic, so any drift
# in the jq filter breaks the build instead of silently passing a stale copy.
VALIDATE_SCRIPT="$SCRIPT_DIR/../scripts/validate-candidates.sh"
[ -f "$VALIDATE_SCRIPT" ] || fail "validate-candidates.sh missing at $VALIDATE_SCRIPT"
# shellcheck source=/dev/null
source "$VALIDATE_SCRIPT"

# ── Test 1: valid candidate, required fields only (no optionals) ──────────────
VALID='[{"content":"c","confidence":"high","source_chat":"/a.jsonl","source_date":"2026-06-01"}]'
OUT=$(validate_candidates "$VALID")
echo "$OUT" | jq 'length' | grep -q "^1$" || fail "valid candidate (required-only) was filtered out"
echo "PASS: valid candidate (required fields only) passes validation"

# ── Test 2: candidate with optional fields also passes ────────────────────────
VALID_OPT='[{"content":"c","confidence":"high","source_chat":"/a.jsonl","source_date":"2026-06-01","type":"world-fact","evidence":"quote","suggested_section":"Skills"}]'
OUT_OPT=$(validate_candidates "$VALID_OPT")
echo "$OUT_OPT" | jq 'length' | grep -q "^1$" || fail "candidate with optional fields was filtered out"
echo "PASS: candidate with optional fields (type, evidence, suggested_section) passes validation"

# ── Test 3: missing source_date (required) → filtered out ────────────────────
MISSING_DATE='[{"content":"c","confidence":"high","source_chat":"/a.jsonl"}]'
OUT_NODATE=$(validate_candidates "$MISSING_DATE")
echo "$OUT_NODATE" | jq 'length' | grep -q "^0$" || fail "candidate missing required source_date was NOT filtered"
echo "PASS: candidate missing required source_date is filtered out"

# ── Test 4: missing confidence (required) → filtered out ─────────────────────
MISSING_CONF='[{"content":"c","source_chat":"/a.jsonl","source_date":"2026-06-01"}]'
OUT_NOCONF=$(validate_candidates "$MISSING_CONF")
echo "$OUT_NOCONF" | jq 'length' | grep -q "^0$" || fail "candidate missing required confidence was NOT filtered"
echo "PASS: candidate missing required confidence is filtered out"

# ── Test 5: missing content (required) → filtered out ────────────────────────
MISSING_CONTENT='[{"confidence":"high","source_chat":"/a.jsonl","source_date":"2026-06-01"}]'
OUT_NOCONTENT=$(validate_candidates "$MISSING_CONTENT")
echo "$OUT_NOCONTENT" | jq 'length' | grep -q "^0$" || fail "candidate missing required content was NOT filtered"
echo "PASS: candidate missing required content is filtered out"

# ── Test 6: missing source_chat (required) → filtered out ────────────────────
MISSING_CHAT='[{"content":"c","confidence":"high","source_date":"2026-06-01"}]'
OUT_NOCHAT=$(validate_candidates "$MISSING_CHAT")
echo "$OUT_NOCHAT" | jq 'length' | grep -q "^0$" || fail "candidate missing required source_chat was NOT filtered"
echo "PASS: candidate missing required source_chat is filtered out"

# ── Test 7: non-array input handled gracefully ───────────────────────────────
# The harness returns empty string (stdout suppressed via 2>/dev/null) on non-array input.
# Accept either: empty string, "[]", or a valid JSON array of length 0.
BAD='{"not":"array"}'
OUT_BAD=$(validate_candidates "$BAD" || true)
if [ -n "$OUT_BAD" ]; then
  # If we got non-empty output it must be a zero-length JSON array
  COUNT=$(printf '%s' "$OUT_BAD" | jq 'length' 2>/dev/null || echo "INVALID")
  [ "$COUNT" = "0" ] || fail "non-array input produced unexpected output: $OUT_BAD"
fi
echo "PASS: non-array input handled gracefully (no crash, no false candidates)"

# ── Test 8: empty array is valid ─────────────────────────────────────────────
OUT_EMPTY=$(validate_candidates "[]")
echo "$OUT_EMPTY" | jq 'length' | grep -q "^0$" || fail "empty array was rejected"
echo "PASS: empty array is valid"

# ── Test 9: mixed array — only valid items survive ───────────────────────────
# One item has all 4 required fields; one is missing source_date; one is missing confidence.
MIXED='[
  {"content":"valid","confidence":"high","source_chat":"/b.jsonl","source_date":"2026-05-01"},
  {"content":"no-date","confidence":"medium","source_chat":"/c.jsonl"},
  {"content":"no-conf","source_chat":"/d.jsonl","source_date":"2026-05-02"}
]'
OUT_MIXED=$(validate_candidates "$MIXED")
echo "$OUT_MIXED" | jq 'length' | grep -q "^1$" || fail "mixed array: expected 1 valid candidate, got something else"
echo "$OUT_MIXED" | jq -r '.[0].content' | grep -q "^valid$" || fail "mixed array: wrong candidate survived"
echo "PASS: mixed array — only the fully-valid candidate survives"

# ── Test 10: optional-fields-missing does NOT drop the fact ──────────────────
# This is the normative invariant from overview §4.
# Confirm type/evidence/suggested_section each independently absent → still valid.
NO_TYPE='[{"content":"c","confidence":"medium","source_chat":"/e.jsonl","source_date":"2026-06-02"}]'
NO_EVIDENCE='[{"content":"c","confidence":"low","source_chat":"/f.jsonl","source_date":"2026-06-02","type":"observation"}]'
NO_SECTION='[{"content":"c","confidence":"high","source_chat":"/g.jsonl","source_date":"2026-06-02","evidence":"quote"}]'
for CASE in "$NO_TYPE" "$NO_EVIDENCE" "$NO_SECTION"; do
  OUT_OPT2=$(validate_candidates "$CASE")
  echo "$OUT_OPT2" | jq 'length' | grep -q "^1$" || fail "optional-fields-missing case filtered incorrectly: $CASE"
done
echo "PASS: optional-fields-missing (type / evidence / suggested_section) never drops a fact"

echo ""
echo "All map harness tests passed."
