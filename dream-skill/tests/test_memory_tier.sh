#!/usr/bin/env bash
# test_memory_tier.sh — validate-candidates.py memory_tier enforcement +
# split-memory-tiers.py routable/audit/dropped partitioning.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$SKILL_DIR/scripts/validate-candidates.sh"
SPLITTER="$SKILL_DIR/scripts/split-memory-tiers.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$SPLITTER" ] || { echo "FAIL: split-memory-tiers.py not executable"; exit 1; }

# ── 1a) validate-candidates.py drops a candidate missing memory_tier ─────────
cat > "$TMP/missing-tier.json" <<'JSON'
[{"content":"The user prefers concise reports.","confidence":"high","source_chat":"chat-a","source_date":"2026-07-01","source_role":"user","source_event":1,"evidence":"I prefer concise reports."}]
JSON
OUT_MISSING=$("$VALIDATOR" < "$TMP/missing-tier.json")
[ "$(printf '%s' "$OUT_MISSING" | jq 'length')" = "0" ] || { echo "FAIL: candidate missing memory_tier was not dropped"; exit 1; }
echo "PASS: candidate missing memory_tier is dropped (not an error exit)"

# ── 1b) validate-candidates.py drops a candidate with an invalid memory_tier ──
cat > "$TMP/bogus-tier.json" <<'JSON'
[{"content":"The user prefers concise reports.","confidence":"high","source_chat":"chat-a","source_date":"2026-07-01","source_role":"user","source_event":1,"evidence":"I prefer concise reports.","memory_tier":"bogus"}]
JSON
OUT_BOGUS=$("$VALIDATOR" < "$TMP/bogus-tier.json")
[ "$(printf '%s' "$OUT_BOGUS" | jq 'length')" = "0" ] || { echo "FAIL: candidate with bogus memory_tier was not dropped"; exit 1; }
echo "PASS: candidate with invalid memory_tier (\"bogus\") is dropped"

# ── 1c) sanity: a valid memory_tier still passes ──────────────────────────────
cat > "$TMP/valid-tier.json" <<'JSON'
[{"content":"The user prefers concise reports.","confidence":"high","source_chat":"chat-a","source_date":"2026-07-01","source_role":"user","source_event":1,"evidence":"I prefer concise reports.","memory_tier":"stable"}]
JSON
OUT_VALID=$("$VALIDATOR" < "$TMP/valid-tier.json")
[ "$(printf '%s' "$OUT_VALID" | jq 'length')" = "1" ] || { echo "FAIL: candidate with valid memory_tier was incorrectly dropped"; exit 1; }
echo "PASS: candidate with valid memory_tier (\"stable\") passes validation"

# ── 2) split-memory-tiers.py partitions stable/current/audit/drop correctly ──
cat > "$TMP/four-tiers.json" <<'JSON'
[
  {"content":"Stable identity fact","confidence":"high","source_chat":"a","source_date":"2026-07-01","memory_tier":"stable"},
  {"content":"Current dated operational state","confidence":"high","source_chat":"b","source_date":"2026-07-01","memory_tier":"current"},
  {"content":"Audit run receipt: 25/25 tests green, commit abc1234","confidence":"high","source_chat":"c","source_date":"2026-07-01","memory_tier":"audit"},
  {"content":"One-off debug churn, never retain this","confidence":"high","source_chat":"d","source_date":"2026-07-01","memory_tier":"drop"}
]
JSON

SPLIT_OUT=$("$SPLITTER" --report < "$TMP/four-tiers.json" 2>"$TMP/split-report.txt")
printf '%s' "$SPLIT_OUT" > "$TMP/split-out.json"

[ "$(jq '.routable | length' "$TMP/split-out.json")" = "2" ] || { echo "FAIL: expected 2 routable candidates"; exit 1; }
jq -e '.routable[0].content == "Stable identity fact" and .routable[1].content == "Current dated operational state"' "$TMP/split-out.json" >/dev/null \
  || { echo "FAIL: routable did not contain exactly the stable+current items in order"; exit 1; }
echo "PASS: routable contains exactly the stable+current candidates, in order"

[ "$(jq '.audit | length' "$TMP/split-out.json")" = "1" ] || { echo "FAIL: expected 1 audit candidate"; exit 1; }
jq -e '.audit[0].content == "Audit run receipt: 25/25 tests green, commit abc1234"' "$TMP/split-out.json" >/dev/null \
  || { echo "FAIL: audit did not contain exactly the audit-tier item"; exit 1; }
echo "PASS: audit contains exactly the audit-tier candidate"

[ "$(jq '.dropped' "$TMP/split-out.json")" = "1" ] || { echo "FAIL: expected dropped count of 1"; exit 1; }
echo "PASS: dropped count is 1"

if jq -e '(.routable + .audit) | map(.content) | any(. == "One-off debug churn, never retain this")' "$TMP/split-out.json" >/dev/null; then
  echo "FAIL: drop-tier candidate content leaked into routable or audit"
  exit 1
fi
if printf '%s' "$SPLIT_OUT" | grep -qF "One-off debug churn"; then
  echo "FAIL: drop-tier candidate content leaked into split-memory-tiers.py output"
  exit 1
fi
echo "PASS: drop-tier candidate content does not appear anywhere in the output"

grep -q "^split-memory-tiers: in=4 routable=2 audit=1 dropped=1$" "$TMP/split-report.txt" \
  || { echo "FAIL: --report summary line missing or wrong: $(cat "$TMP/split-report.txt")"; exit 1; }
echo "PASS: --report prints the one-line in/routable/audit/dropped summary"

# ── 3) split-memory-tiers.py defensively rejects a missing/invalid memory_tier ─
cat > "$TMP/bad-input.json" <<'JSON'
[{"content":"no tier here","confidence":"high","source_chat":"e","source_date":"2026-07-01"}]
JSON
if "$SPLITTER" < "$TMP/bad-input.json" >/dev/null 2>&1; then
  echo "FAIL: split-memory-tiers.py accepted a candidate with a missing memory_tier"
  exit 1
fi
echo "PASS: split-memory-tiers.py errors out on a candidate with a missing memory_tier"

echo "test_memory_tier: ok"
