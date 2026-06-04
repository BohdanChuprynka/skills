#!/usr/bin/env bash
# validate-candidates.sh — the single source of truth for MAP output validation.
#
# Filters a candidate-fact JSON array (a MAP subagent's output) to the items that
# carry ALL FOUR required fields (overview §4):
#   content, confidence, source_chat, source_date
# Optional fields (type, evidence, suggested_section) NEVER cause a drop.
# Non-array input → jq error + non-zero exit (stderr suppressed, matching the harness).
#
# Used by BOTH the orchestrator (SKILL.md Step 2 sources/runs this) and the unit test
# (tests/test_map_harness.sh sources it) so the tested logic IS the shipped logic —
# no re-typed copy that can silently drift (see REVIEW-2026-06-04 M4).
#
# Usage:
#   source validate-candidates.sh ; validate_candidates '<json>'   # as a function
#   printf '%s' '<json>' | validate-candidates.sh                  # as a script (stdin→stdout)

validate_candidates() {
  local json="$1"
  printf '%s' "$json" | jq 'if type == "array" then
    map(
      select(
        has("content") and has("confidence") and has("source_chat")
        and has("source_date")
      )
    )
  else error("not an array") end' 2>/dev/null
}

# When executed directly (not sourced), validate stdin.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -uo pipefail
  command -v jq >/dev/null 2>&1 || { echo "validate-candidates: jq required" >&2; exit 1; }
  validate_candidates "$(cat)"
fi
