#!/usr/bin/env bash
# Static contract checks for ROUTE prompt dependencies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SKILL="$ROOT/skills/dream-skill/SKILL.md"
ROUTING="$ROOT/ROUTING.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SKILL" ] || fail "missing SKILL.md at $SKILL"
[ -r "$ROUTING" ] || fail "missing readable ROUTING.md at $ROUTING"

grep -q 'ROUTING_MD="$DREAM_SKILL_HOME/ROUTING.md"' "$SKILL" \
  || fail "SKILL.md does not resolve ROUTING.md from DREAM_SKILL_HOME"
grep -q '\[ -r "$ROUTING_MD" \]' "$SKILL" \
  || fail "SKILL.md preflight does not fail loud when ROUTING.md is missing"
grep -q 'build-route-batches.py' "$SKILL" \
  || fail "SKILL.md does not build route batches"
grep -q 'validate-route-batch.py' "$SKILL" \
  || fail "SKILL.md does not validate route batch outputs"
grep -q 'Every input `candidate_id` MUST appear exactly once' "$SKILL" \
  || fail "SKILL.md route prompt does not enforce one output per candidate_id"

grep -q '^## 1\. Which vault\?' "$ROUTING" \
  || fail "ROUTING.md missing vault disambiguation rules"
grep -q '^## 4\. Confidence calibration' "$ROUTING" \
  || fail "ROUTING.md missing confidence calibration"

echo "PASS: ROUTE prompt dependencies are present and fail-loud"
