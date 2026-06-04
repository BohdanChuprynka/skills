#!/usr/bin/env bash
# Tests for check-pending.sh (last-run nudge behavior)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/check-pending.sh"

[ -x "$CHECK" ] || { echo "FAIL: check-pending.sh missing or not executable"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

TMP=$(mktemp -d "/tmp/dream-check-nudge-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Test 1: no marker file → silent, exit 0
OUT=$(DREAM_MARKER_DIR="$TMP" "$CHECK" 2>&1)
[ -z "$OUT" ] || fail "no-marker: expected silent output, got: $OUT"
echo "PASS: no marker → silent + exit 0"

# Test 2: marker file present → outputs nudge line containing the date
echo "2026-06-01" > "$TMP/last-run"
OUT=$(DREAM_MARKER_DIR="$TMP" "$CHECK" 2>&1)
printf '%s' "$OUT" | grep -q "2026-06-01" || fail "marker present: output missing date (got: $OUT)"
printf '%s' "$OUT" | grep -q "dream-skill" || fail "marker present: output missing 'dream-skill' (got: $OUT)"
echo "PASS: marker present → nudge line with date"

# Test 3: always exits 0 (even with a marker)
DREAM_MARKER_DIR="$TMP" "$CHECK" || fail "non-zero exit with marker present"
echo "PASS: always exits 0"

# Test 4: empty marker file → silent (no date to show)
printf '' > "$TMP/last-run"
OUT=$(DREAM_MARKER_DIR="$TMP" "$CHECK" 2>&1)
[ -z "$OUT" ] || fail "empty marker: expected silent output, got: $OUT"
echo "PASS: empty marker file → silent"

echo
echo "All check-pending.sh tests passed."
