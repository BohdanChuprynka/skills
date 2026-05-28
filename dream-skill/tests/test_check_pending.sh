#!/usr/bin/env bash
# Test: check-pending.sh — orphan SPAWNED detection + idempotent WARNING
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/check-pending.sh"
FIX="$SCRIPT_DIR/fixtures"

[ -x "$CHECK" ] || { echo "FAIL: check-pending.sh missing or not executable"; exit 1; }

TMP=$(mktemp -d "/tmp/dream-check-pending-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Fixtures use timestamps from 2026-05-27 → expand lookback window so they
# remain "inside" the scan range. Per-test cases override GRACE as needed.
export DREAM_ORPHAN_WINDOW_SEC=99999999999

fail() {
  echo "FAIL: $*"
  echo "--- $DREAM_LOG was ---"
  cat "$DREAM_LOG" 2>/dev/null || echo "(missing)"
  exit 1
}

# Helper: count WARNING orphan lines in the current log.
# grep -c returns rc=1 when no matches; trap that so it doesn't tank `set -e`.
count_warnings() {
  [ -f "$DREAM_LOG" ] || { echo 0; return; }
  local n
  n=$(grep -c "WARNING kind=orphan" "$DREAM_LOG" 2>/dev/null || true)
  echo "${n:-0}"
}

# === T1: orphan outside grace → appends WARNING ===
cp "$FIX/trigger-log-orphan.txt" "$TMP/orphan.log"
export DREAM_LOG="$TMP/orphan.log"
export DREAM_ORPHAN_GRACE_SEC=0   # disable grace for this case
"$CHECK"
WARN=$(count_warnings)
[ "$WARN" -eq 1 ] || fail "expected 1 WARNING for orphan, got $WARN"
grep -q "WARNING kind=orphan.*conv-A.jsonl" "$DREAM_LOG" \
  || fail "WARNING line missing or has wrong transcript"
echo "PASS: orphan → appends WARNING line"

# === T2: completed spawn → no WARNING ===
cp "$FIX/trigger-log-completed.txt" "$TMP/completed.log"
export DREAM_LOG="$TMP/completed.log"
"$CHECK"
WARN=$(count_warnings)
[ "$WARN" -eq 0 ] || fail "completed spawn wrongly produced WARNING (count=$WARN)"
echo "PASS: completed spawn → silent"

# === T3: errored spawn → no orphan WARNING (ERROR already resolves it) ===
cp "$FIX/trigger-log-errored.txt" "$TMP/errored.log"
export DREAM_LOG="$TMP/errored.log"
"$CHECK"
WARN=$(count_warnings)
[ "$WARN" -eq 0 ] || fail "errored spawn wrongly produced WARNING (count=$WARN)"
echo "PASS: errored spawn → silent (ERROR already recorded)"

# === T4: already-warned spawn → no duplicate WARNING ===
cp "$FIX/trigger-log-already-warned.txt" "$TMP/warned.log"
export DREAM_LOG="$TMP/warned.log"
BEFORE=$(count_warnings)
[ "$BEFORE" -eq 1 ] || fail "fixture should start with 1 WARNING (got $BEFORE)"
"$CHECK"
AFTER=$(count_warnings)
[ "$AFTER" -eq 1 ] || fail "already-warned orphan was re-warned (final count=$AFTER)"
echo "PASS: already-warned orphan → no duplicate"

# === T5: missing log file → silent, exit 0 ===
export DREAM_LOG="$TMP/nonexistent.log"
"$CHECK" || fail "non-zero exit on missing log"
echo "PASS: missing log → silent + exit 0"

# === T6: malformed line → silent skip, exit 0 ===
echo "garbage non-parseable line" > "$TMP/malformed.log"
export DREAM_LOG="$TMP/malformed.log"
"$CHECK" || fail "non-zero exit on malformed log"
echo "PASS: malformed log → exit 0"

# === T7: spawn within grace window → no WARNING ===
cp "$FIX/trigger-log-orphan.txt" "$TMP/fresh.log"
export DREAM_LOG="$TMP/fresh.log"
export DREAM_ORPHAN_GRACE_SEC=99999999   # absurdly large grace
"$CHECK"
WARN=$(count_warnings)
[ "$WARN" -eq 0 ] || fail "spawn within grace wrongly produced WARNING (count=$WARN)"
echo "PASS: spawn within grace → silent"

# === T8: idempotent — running check twice produces only 1 WARNING per orphan ===
cp "$FIX/trigger-log-orphan.txt" "$TMP/dual.log"
export DREAM_LOG="$TMP/dual.log"
export DREAM_ORPHAN_GRACE_SEC=0
"$CHECK"
"$CHECK"
WARN=$(count_warnings)
[ "$WARN" -eq 1 ] || fail "duplicate run produced extra WARNINGs (count=$WARN)"
echo "PASS: duplicate runs idempotent (1 WARNING per orphan)"

echo
echo "All check-pending tests passed."
