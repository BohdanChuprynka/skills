#!/usr/bin/env bash
# Static contract test for SKILL.md MAP prefilter integration.
# This catches prompt drift: MAP agents must read filtered text while candidate
# provenance remains the original raw transcript.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SKILL="$ROOT/skills/dream-skill/SKILL.md"

fail() { echo "FAIL: $*"; exit 1; }

[ -f "$SKILL" ] || fail "missing SKILL.md at $SKILL"

grep -q 'prefilter-transcript.py' "$SKILL" \
  || fail "SKILL.md does not require/use prefilter-transcript.py"
grep -q -- '--stats "$transcript" > "$FILTERED_TRANSCRIPT"' "$SKILL" \
  || fail "SKILL.md missing exact --stats prefilter command"
grep -q 'Read the filtered transcript at `<filtered_path>`' "$SKILL" \
  || fail "MAP dispatch prompt does not tell agents to read filtered_path"
grep -q 'Do NOT open the raw transcript' "$SKILL" \
  || fail "MAP dispatch prompt does not forbid opening raw transcript"
grep -q 'set `source_chat` exactly to `<raw_path>`' "$SKILL" \
  || fail "MAP dispatch prompt does not pin source_chat to raw_path"
grep -q 'set `source_date` exactly to `<source_date>`' "$SKILL" \
  || fail "MAP dispatch prompt does not pin source_date"
grep -q 'filtered transcript is still > ~100 KB' "$SKILL" \
  || fail "monster chunking is not based on filtered transcript size"

grep -q 'Read the transcript at `<absolute_path>`' "$SKILL" \
  && fail "old raw-transcript MAP prompt still present"
grep -q 'derive from the transcript filename or metadata' "$SKILL" \
  && fail "source_date is still delegated to filtered transcript metadata"

echo "PASS: SKILL.md MAP prefilter contract is explicit"
