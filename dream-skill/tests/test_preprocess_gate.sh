#!/usr/bin/env bash
# Test: preprocess-gate.sh returns a TRUSTWORTHY emptiness verdict via EXIT CODE,
# so the headless auto-run never has to *judge* whether a transcript is empty:
#   exit 0  OK     — valid transcript with real content; cleaned text on stdout
#   exit 3  EMPTY  — valid transcript, but nothing survives cleaning (stdout blank)
#   exit 2  ERROR  — missing / unreadable / corrupt transcript, or jq unavailable
# This is the deterministic backstop for the v0.2 false-skip bug, where a rich
# 5.8 KB transcript was reported "empty after preprocessing" by the headless LLM.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../scripts/preprocess-gate.sh"
FIX="$SCRIPT_DIR/fixtures"

[ -f "$GATE" ] || { echo "FAIL: preprocess-gate.sh missing at $GATE"; exit 1; }

fail() { echo "FAIL: $*"; echo "--- stdout was ---"; printf '%s\n' "${OUT:-(none)}"; exit 1; }

# --- OK: rich transcript (1 genuine user msg + assistant text) → exit 0 + content ---
OUT=$(bash "$GATE" "$FIX/transcript-real-format.jsonl"); RC=$?
[ "$RC" -eq 0 ] || fail "rich transcript: expected exit 0 (OK), got $RC"
printf '%s' "$OUT" | grep -q "Help me plan tomorrow" || fail "rich transcript: cleaned user text not on stdout"
echo "PASS: rich transcript → OK (exit 0) with content on stdout"

# --- EMPTY: valid JSONL, but only metadata/tool/thinking → exit 3, blank stdout ---
OUT=$(bash "$GATE" "$FIX/transcript-empty-clean.jsonl"); RC=$?
[ "$RC" -eq 3 ] || fail "metadata-only transcript: expected exit 3 (EMPTY), got $RC"
[ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ] || fail "EMPTY case leaked content on stdout"
echo "PASS: metadata/tool-only transcript → EMPTY (exit 3), blank stdout"

# --- ERROR: corrupt/unparseable JSONL → exit 2 (must NOT be misread as empty) ---
OUT=$(bash "$GATE" "$FIX/transcript-corrupt.jsonl"); RC=$?
[ "$RC" -eq 2 ] || fail "corrupt transcript: expected exit 2 (ERROR), got $RC"
echo "PASS: corrupt JSONL → ERROR (exit 2), not silently EMPTY"

# --- ERROR: missing file → exit 2 ---
OUT=$(bash "$GATE" "/tmp/dream-gate-nonexistent-$$.jsonl"); RC=$?
[ "$RC" -eq 2 ] || fail "missing file: expected exit 2 (ERROR), got $RC"
echo "PASS: missing transcript → ERROR (exit 2)"

# --- ERROR: no path arg → exit 2 ---
OUT=$(bash "$GATE"); RC=$?
[ "$RC" -eq 2 ] || fail "no arg: expected exit 2 (ERROR), got $RC"
echo "PASS: missing path arg → ERROR (exit 2)"

# --- set -e CALLER SAFETY: the documented routing pattern survives `set -e` ---
# A naive `OUT=$(gate); RC=$?` aborts before RC=$? under set -e; the guarded
# `if clean=$(gate); then ... else rc=$? ...` form (used in SKILL.md Step 1) must not.
route() {
  bash -c '
    set -euo pipefail
    if clean=$(bash "$1" "$2" 2>/dev/null); then echo "OK"; else echo "rc=$?"; fi
  ' _ "$GATE" "$1"
}
[ "$(route "$FIX/transcript-real-format.jsonl")"  = "OK"   ] || fail "set-e routing (ok) wrong"
[ "$(route "$FIX/transcript-empty-clean.jsonl")"  = "rc=3" ] || fail "set-e routing (empty) wrong"
[ "$(route "$FIX/transcript-corrupt.jsonl")"      = "rc=2" ] || fail "set-e routing (error) wrong"
echo "PASS: set-e-safe caller routing pattern (OK / EMPTY / ERROR)"

# --- ERROR: jq unavailable → exit 2 (NOT a false EMPTY) ---
# The whole bug class is "silent false-empty"; jq-missing must be loud.
OUT=$(PATH=/var/empty /bin/bash "$GATE" "$FIX/transcript-real-format.jsonl" 2>/dev/null); RC=$?
[ "$RC" -eq 2 ] || fail "jq unavailable: expected exit 2 (ERROR), got $RC"
echo "PASS: jq unavailable → ERROR (exit 2), not false EMPTY"

# --- ERROR: preprocess.sh missing next to the gate → exit 2 ---
TMPG=$(mktemp -d /tmp/dream-gate-miss-XXXXXX); cp "$GATE" "$TMPG/preprocess-gate.sh"
OUT=$(bash "$TMPG/preprocess-gate.sh" "$FIX/transcript-real-format.jsonl" 2>/dev/null); RC=$?
rm -rf "$TMPG"
[ "$RC" -eq 2 ] || fail "preprocess.sh missing: expected exit 2 (ERROR), got $RC"
echo "PASS: preprocess.sh missing next to gate → ERROR (exit 2)"

# --- ERROR: preprocess.sh exits non-zero → exit 2 (NOT misread as EMPTY) ---
TMPG=$(mktemp -d /tmp/dream-gate-rc-XXXXXX); cp "$GATE" "$TMPG/preprocess-gate.sh"
printf '#!/usr/bin/env bash\nexit 7\n' > "$TMPG/preprocess.sh"; chmod +x "$TMPG/preprocess.sh"
OUT=$(bash "$TMPG/preprocess-gate.sh" "$FIX/transcript-real-format.jsonl" 2>/dev/null); RC=$?
rm -rf "$TMPG"
[ "$RC" -eq 2 ] || fail "preprocess.sh non-zero exit: expected exit 2 (ERROR), got $RC"
echo "PASS: preprocess.sh non-zero exit → ERROR (exit 2), not EMPTY"

echo
echo "All preprocess-gate.sh tests passed."
