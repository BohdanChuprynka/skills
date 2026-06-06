#!/usr/bin/env bash
# Static contract test for SKILL.md MAP step.
# Catches prompt drift: MAP must (1) prefilter, (2) build single-Read units via
# build-map-batches.py, (3) instruct agents to read each unit in ONE Read call
# (the anti-multi-turn-multiplier contract), while candidate provenance stays the
# original raw transcript. Regressions here silently reintroduce the 17x token blowup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SKILL="$ROOT/skills/dream-skill/SKILL.md"

fail() { echo "FAIL: $*"; exit 1; }

[ -f "$SKILL" ] || fail "missing SKILL.md at $SKILL"

# --- prefilter still required ---
grep -q 'prefilter-transcript.py' "$SKILL" \
  || fail "SKILL.md does not require/use prefilter-transcript.py"
grep -q -- '--stats "$transcript" > "$FILTERED_TRANSCRIPT"' "$SKILL" \
  || fail "SKILL.md missing exact --stats prefilter command"

# --- single-Read unit builder wired in ---
grep -q 'build-map-batches.py' "$SKILL" \
  || fail "SKILL.md does not build single-Read MAP units via build-map-batches.py"
grep -q 'build-map-batches.py" --workdir "\$WORKDIR"' "$SKILL" \
  || fail "SKILL.md missing build-map-batches.py --workdir invocation"

# --- anti-multiplier read contract ---
grep -q 'Read the MAP unit at `<unit_path>` with a SINGLE Read call' "$SKILL" \
  || fail "MAP prompt does not instruct a single-Read of the unit"
grep -q 'Do NOT make multiple Read calls' "$SKILL" \
  || fail "MAP prompt does not forbid multiple Read calls (multiplier guard)"
grep -q 'do NOT open any raw transcript' "$SKILL" \
  || fail "MAP prompt does not forbid opening the raw transcript"

# --- provenance pinned ---
grep -q 'set `source_chat` exactly to `<source_chat>` and `source_date` exactly to `<source_date>`' "$SKILL" \
  || fail "MAP prompt does not pin source_chat/source_date for chunk units"
grep -q 'DREAM-MAP-UNIT source_chat=' "$SKILL" \
  || fail "MAP prompt does not describe bundle separator provenance"

# --- the OLD multi-turn-multiplier instruction must be gone ---
grep -q 'chunk the filtered text into overlapping 40 KB segments' "$SKILL" \
  && fail "old self-chunking multi-turn instruction still present (reintroduces the multiplier)"
grep -q 'Read the filtered transcript at `<filtered_path>`' "$SKILL" \
  && fail "old per-transcript MAP prompt still present"
grep -q 'Read the transcript at `<absolute_path>`' "$SKILL" \
  && fail "ancient raw-transcript MAP prompt still present"

echo "PASS: SKILL.md MAP step enforces single-Read units (no multi-turn multiplier)"
