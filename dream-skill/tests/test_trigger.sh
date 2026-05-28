#!/usr/bin/env bash
# Test: trigger.sh threshold gating + dedupe lock + stdin/env paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
TRIGGER="$SCRIPT_DIR/../scripts/trigger.sh"

[ -x "$TRIGGER" ] || { echo "FAIL: trigger.sh missing or not executable at $TRIGGER"; exit 1; }

# Isolate test state
export DREAM_DISPATCH_STUB=1
export DREAM_LOG=/tmp/dream-test-trigger-$$.log
export DREAM_LOCK_DIR=/tmp/dream-test-locks-$$
trap 'rm -rf "$DREAM_LOG" "$DREAM_LOCK_DIR"' EXIT
rm -rf "$DREAM_LOG" "$DREAM_LOCK_DIR"

fail() { echo "FAIL: $*"; echo "--- log was ---"; cat "$DREAM_LOG" 2>/dev/null; exit 1; }
reset_log() { rm -f "$DREAM_LOG"; rm -rf "$DREAM_LOCK_DIR"; mkdir -p "$DREAM_LOCK_DIR"; }

# === Case 1: 3-msg fixture → below threshold SKIP ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-3msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "3-msg fixture triggered DISPATCH"
grep -q "below-threshold" "$DREAM_LOG" 2>/dev/null || fail "3-msg fixture did not log below-threshold"
echo "PASS: 3-message fixture skipped (below-threshold)"

# === Case 2: 15-msg fixture → DISPATCH ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "15-msg fixture did not dispatch"
echo "PASS: 15-message fixture dispatched"

# === Case 3: empty path → SKIP no-path-provided ===
reset_log
CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER" < /dev/null
grep -q "no-path-provided" "$DREAM_LOG" 2>/dev/null || fail "empty path did not log no-path-provided"
echo "PASS: empty path → no-path-provided"

# === Case 4: nonexistent file → SKIP file-not-found (distinct from no-path) ===
reset_log
CLAUDE_TRANSCRIPT_PATH="/tmp/nonexistent-$$.jsonl" "$TRIGGER"
grep -q "file-not-found" "$DREAM_LOG" 2>/dev/null || fail "nonexistent file did not log file-not-found"
echo "PASS: nonexistent file → file-not-found"

# === Case 5: stdin JSON path triggers dispatch ===
reset_log
echo "{\"session_id\":\"test\",\"transcript_path\":\"$FIXTURE_DIR/transcript-15msg.jsonl\",\"cwd\":\"/tmp\",\"reason\":\"exit\"}" \
  | CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "stdin-JSON did not dispatch"
echo "PASS: stdin-JSON dispatches"

# === Case 6: per-transcript lock — second dispatch within TTL is suppressed ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
DISPATCH_COUNT=$(grep -c "DISPATCH" "$DREAM_LOG" 2>/dev/null || echo 0)
[ "$DISPATCH_COUNT" -eq 1 ] || fail "first call should DISPATCH once, got $DISPATCH_COUNT"

CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
DISPATCH_COUNT_AFTER=$(grep -c "DISPATCH" "$DREAM_LOG" 2>/dev/null || echo 0)
[ "$DISPATCH_COUNT_AFTER" -eq 1 ] || fail "second call within TTL re-dispatched (count=$DISPATCH_COUNT_AFTER, expected 1)"

grep -q "duplicate-dispatch" "$DREAM_LOG" 2>/dev/null || fail "second call did not log duplicate-dispatch"
echo "PASS: per-transcript lock suppresses duplicate dispatch within TTL"

# === Case 7: lock expires past TTL → re-dispatch allowed ===
reset_log
export DREAM_LOCK_TTL_SEC=1
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
sleep 2
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
DISPATCH_COUNT=$(grep -c "DISPATCH" "$DREAM_LOG" 2>/dev/null || echo 0)
[ "$DISPATCH_COUNT" -eq 2 ] || fail "after TTL expiry, expected 2 dispatches, got $DISPATCH_COUNT"
unset DREAM_LOCK_TTL_SEC
echo "PASS: expired lock allows re-dispatch"

# === Case 8: reason=clear → SKIP ===
reset_log
echo "{\"transcript_path\":\"$FIXTURE_DIR/transcript-15msg.jsonl\",\"reason\":\"clear\"}" \
  | CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "reason=clear triggered dispatch"
grep -q "reason=clear" "$DREAM_LOG" 2>/dev/null || fail "reason=clear not logged"
echo "PASS: reason=clear skipped"

# === Case 9: claude-p exit code captured by wrapper ===
# Override `claude` with a stub that exits with code 7. Wrapper should log ERROR.
reset_log
STUB_DIR=$(mktemp -d "/tmp/dream-claude-stub-XXXXXX")
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$STUB_DIR/claude"

# Disable stub mode so real spawn-wrapper runs (against our fake claude)
unset DREAM_DISPATCH_STUB || true
PATH="$STUB_DIR:$PATH" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"

# Wait briefly for background wrapper (stub exits immediately, but log
# append happens after disown → poll up to 3s)
for i in 1 2 3 4 5 6; do
  grep -q "ERROR source=claude-p code=7" "$DREAM_LOG" 2>/dev/null && break
  sleep 0.5
done

grep -q "ERROR source=claude-p code=7" "$DREAM_LOG" \
  || fail "wrapper did not log ERROR for claude-p exit 7"
echo "PASS: wrapper captures claude-p non-zero exit + logs ERROR"

# Cleanup + restore stub mode for any future cases
rm -rf "$STUB_DIR"
export DREAM_DISPATCH_STUB=1

echo
echo "All trigger.sh tests passed."
