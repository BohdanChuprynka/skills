#!/usr/bin/env bash
# validate-candidates.sh — the single source of truth for MAP output validation.
#
# Thin compatibility wrapper around validate-candidates.py. Pass --unit and
# --source-chat to enforce exact evidence provenance against a MAP unit.
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
  shift || true
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$json" | python3 "$script_dir/validate-candidates.py" "$@"
}

# When executed directly (not sourced), validate stdin.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -uo pipefail
  validate_candidates "$(cat)" "$@"
fi
