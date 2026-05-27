#!/usr/bin/env bash
# Test: trigger.sh threshold-gated dispatch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
TRIGGER="$SCRIPT_DIR/../scripts/trigger.sh"

[ -x "$TRIGGER" ] || { echo "FAIL: trigger.sh missing or not executable at $TRIGGER"; exit 1; }

# Isolate test state
export DREAM_DISPATCH_STUB=1
export DREAM_LOG=/tmp/dream-test-trigger-$$.log
trap 'rm -f "$DREAM_LOG"' EXIT
rm -f "$DREAM_LOG"

fail() { echo "FAIL: $*"; exit 1; }

# Case 1: 3-message fixture (below threshold) → SKIP
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-3msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "3-msg fixture triggered DISPATCH"
grep -q "SKIP" "$DREAM_LOG" 2>/dev/null || fail "3-msg fixture did not log SKIP"
echo "PASS: 3-message fixture skipped dispatch"

# Reset log between cases
rm -f "$DREAM_LOG"

# Case 2: 15-message fixture (above threshold) → DISPATCH
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "15-msg fixture did not log DISPATCH"
echo "PASS: 15-message fixture dispatched"

# Reset log
rm -f "$DREAM_LOG"

# Case 3: missing transcript path → SKIP (no error)
CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER"
grep -q "no-transcript" "$DREAM_LOG" 2>/dev/null || fail "empty path did not log no-transcript skip"
echo "PASS: empty transcript path handled gracefully"

# Reset log
rm -f "$DREAM_LOG"

# Case 4: nonexistent transcript path → SKIP
CLAUDE_TRANSCRIPT_PATH="/tmp/nonexistent-transcript-$$.jsonl" "$TRIGGER"
grep -q "no-transcript" "$DREAM_LOG" 2>/dev/null || fail "nonexistent path did not log no-transcript skip"
echo "PASS: nonexistent transcript path handled gracefully"

# Reset log
rm -f "$DREAM_LOG"

# Case 5: transcript path supplied via stdin JSON (Claude Code's actual mechanism)
echo "{\"session_id\":\"test\",\"transcript_path\":\"$FIXTURE_DIR/transcript-15msg.jsonl\",\"cwd\":\"/tmp\",\"reason\":\"exit\"}" \
  | CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "stdin-JSON path did not dispatch"
echo "PASS: stdin-JSON transcript path triggers dispatch"

echo
echo "All trigger.sh tests passed."
