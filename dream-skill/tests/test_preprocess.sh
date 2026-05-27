#!/usr/bin/env bash
# Test: preprocess.sh strips noise, keeps user/assistant text
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREP="$SCRIPT_DIR/../scripts/preprocess.sh"
FIX="$SCRIPT_DIR/fixtures/transcript-noisy.jsonl"

[ -x "$PREP" ] || { echo "FAIL: preprocess.sh missing or not executable"; exit 1; }
[ -f "$FIX" ] || { echo "FAIL: fixture missing"; exit 1; }

OUT=$("$PREP" "$FIX")

fail() { echo "FAIL: $*"; echo "--- output was ---"; echo "$OUT"; exit 1; }

# Must KEEP text content (user + assistant, structured and plain-string)
echo "$OUT" | grep -q "Help me plan tomorrow"          || fail "missing user text 1"
echo "$OUT" | grep -q "Sure. Calendar shows 3 events"  || fail "missing assistant text 1"
echo "$OUT" | grep -q "Schedule 9am block for project X" || fail "missing user text 2"
echo "$OUT" | grep -q "Locked in 9am block"            || fail "missing assistant text 2"
echo "$OUT" | grep -q "Plain string content also works" || fail "missing plain string user"
echo "$OUT" | grep -q "And plain string assistant reply" || fail "missing plain string assistant"

# Must STRIP tool_use input, tool_result content, system-reminder, hook output
echo "$OUT" | grep -q "BIG_MCP_DATA_BLOB"  && fail "tool_result content leaked"
echo "$OUT" | grep -q "system-reminder"    && fail "system-reminder tag leaked"
echo "$OUT" | grep -q "some hook text"     && fail "hook content leaked"
echo "$OUT" | grep -q "tool_use"           && fail "tool_use block leaked"
echo "$OUT" | grep -q "2026-05-28"         && fail "tool_use input args leaked"

echo "PASS: preprocess strips noise, keeps text content"
echo
echo "All preprocess.sh tests passed."
