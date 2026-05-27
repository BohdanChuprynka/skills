#!/usr/bin/env bash
# Test: preprocess.sh strips noise across both Claude Code formats
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREP="$SCRIPT_DIR/../scripts/preprocess.sh"
FIX_SIMPLE="$SCRIPT_DIR/fixtures/transcript-noisy.jsonl"
FIX_REAL="$SCRIPT_DIR/fixtures/transcript-real-format.jsonl"

[ -x "$PREP" ] || { echo "FAIL: preprocess.sh missing or not executable"; exit 1; }
[ -f "$FIX_SIMPLE" ] || { echo "FAIL: simple fixture missing"; exit 1; }
[ -f "$FIX_REAL" ] || { echo "FAIL: real fixture missing"; exit 1; }

fail() { echo "FAIL: $*"; echo "--- output was ---"; echo "${OUT:-(none)}"; exit 1; }

# ============================================================
# Format 1: simple top-level {role, content}
# ============================================================
OUT=$("$PREP" "$FIX_SIMPLE")

echo "$OUT" | grep -q "Help me plan tomorrow"           || fail "[simple] missing user text 1"
echo "$OUT" | grep -q "Sure. Calendar shows 3 events"   || fail "[simple] missing assistant text 1"
echo "$OUT" | grep -q "Schedule 9am block for project X" || fail "[simple] missing user text 2"
echo "$OUT" | grep -q "Locked in 9am block"             || fail "[simple] missing assistant text 2"
echo "$OUT" | grep -q "Plain string content also works" || fail "[simple] missing plain string user"
echo "$OUT" | grep -q "And plain string assistant reply" || fail "[simple] missing plain string assistant"

echo "$OUT" | grep -q "BIG_MCP_DATA_BLOB"  && fail "[simple] tool_result content leaked"
echo "$OUT" | grep -q "system-reminder"    && fail "[simple] system-reminder tag leaked"
echo "$OUT" | grep -q "some hook text"     && fail "[simple] hook content leaked"
echo "$OUT" | grep -q "tool_use"           && fail "[simple] tool_use block leaked"
echo "$OUT" | grep -q "2026-05-28"         && fail "[simple] tool_use input args leaked"
echo "PASS: simple top-level format"

# ============================================================
# Format 2: real Claude Code nested {type, message:{role,content}, isMeta}
# ============================================================
OUT=$("$PREP" "$FIX_REAL")

# Must KEEP real user + assistant text content
echo "$OUT" | grep -q "Help me plan tomorrow"            || fail "[real] missing user text 1"
echo "$OUT" | grep -q "Sure. Calendar shows 3 events"    || fail "[real] missing assistant text 1"
echo "$OUT" | grep -q "Schedule 9am block for project X"  || fail "[real] missing user text 2"
echo "$OUT" | grep -q "Locked in 9am block for project X" || fail "[real] missing assistant text 2"

# Must STRIP: thinking, tool_use, tool_result, isMeta lines, attachment, ai-title,
#             system-reminder tags, local-command-caveat tags, permission-mode entries
echo "$OUT" | grep -q "internal reasoning"  && fail "[real] thinking block leaked"
echo "$OUT" | grep -q "BIG_MCP_DATA_BLOB_REAL" && fail "[real] tool_result content leaked"
echo "$OUT" | grep -q "caveat text"         && fail "[real] isMeta caveat leaked"
echo "$OUT" | grep -q "system-reminder"     && fail "[real] system-reminder tag leaked"
echo "$OUT" | grep -q "noise from hook"     && fail "[real] hook content leaked"
echo "$OUT" | grep -q "tool_use"            && fail "[real] tool_use block leaked"
echo "$OUT" | grep -q "2026-05-28"          && fail "[real] tool_use input args leaked"
echo "$OUT" | grep -q "Plan tomorrow"       && fail "[real] ai-title leaked"
echo "$OUT" | grep -q "permission-mode"     && fail "[real] permission-mode entry leaked"
echo "PASS: real Claude Code nested format"

echo
echo "All preprocess.sh tests passed."
