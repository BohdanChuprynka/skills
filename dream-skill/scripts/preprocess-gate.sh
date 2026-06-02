#!/usr/bin/env bash
# dream-skill content gate.
# Wraps preprocess.sh with input validation and turns "is this transcript
# empty?" into a DETERMINISTIC shell fact, surfaced via EXIT CODE so the
# headless auto-run never has to *judge* emptiness from eyeballed output:
#
#   exit 0  OK     — valid transcript with real content; cleaned text on stdout
#   exit 3  EMPTY  — valid transcript, but nothing survives cleaning (stdout blank)
#   exit 2  ERROR  — missing / unreadable / corrupt transcript, or jq unavailable
#
# Callers (SKILL.md Step 1, trigger.sh) MUST route on $? using the set-e-safe
# form `if clean=$(preprocess-gate.sh "$T"); then …OK… else rc=$?; …; fi`.
# A bare `clean=$(…); rc=$?` aborts before `rc=$?` under `set -e`.
#
# Background: v0.2 let the headless LLM decide emptiness by reading preprocess.sh
# output; on a rich 5.8 KB transcript it falsely reported "empty after
# preprocessing" and silently skipped the session. This gate removes that
# discretion: emptiness is a byte count, corruption is an ERROR (not a false
# EMPTY), and a missing path is an ERROR (not a false EMPTY).

set -uo pipefail   # deliberately NOT -e: this script decides its own exit code
                   # and must never abort mid-decision (that reintroduces the bug).

TRANSCRIPT="${1:-}"

[ -n "$TRANSCRIPT" ] || { echo "preprocess-gate: no transcript path given" >&2; exit 2; }
[ -f "$TRANSCRIPT" ] || { echo "preprocess-gate: no such file: $TRANSCRIPT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "preprocess-gate: jq required" >&2; exit 2; }

# Corrupt / truncated JSONL (e.g. a mid-compaction partial flush) would otherwise
# pass through preprocess.sh's trailing `|| true` as blank output and be
# misclassified EMPTY → silently dropped. Surface it as ERROR instead.
jq empty "$TRANSCRIPT" >/dev/null 2>&1 \
  || { echo "preprocess-gate: unparseable JSONL: $TRANSCRIPT" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREP="$SCRIPT_DIR/preprocess.sh"
[ -f "$PREP" ] || { echo "preprocess-gate: missing preprocess.sh next to gate" >&2; exit 2; }

# No -e, so a non-zero preprocess exit is captured (not fatal) and routed to ERROR.
CLEAN="$(bash "$PREP" "$TRANSCRIPT" 2>/dev/null)"; PP_RC=$?
[ "$PP_RC" -eq 0 ] || { echo "preprocess-gate: preprocess.sh exited $PP_RC" >&2; exit 2; }

if [ -n "$(printf '%s' "$CLEAN" | tr -d '[:space:]')" ]; then
  printf '%s\n' "$CLEAN"
  exit 0      # OK — real content
fi
exit 3        # EMPTY — valid transcript, nothing survives cleaning
