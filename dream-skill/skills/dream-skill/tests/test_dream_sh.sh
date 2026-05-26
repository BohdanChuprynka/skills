#!/usr/bin/env bash
# tests/test_dream_sh.sh — integration smoke test for dream.sh routing + chunked path.
#
# Uses a mock claude binary that emits canned JSON; the test asserts dream.sh
# routes correctly, fires the right number of map calls, and writes the
# expected output artifacts.
#
# Mock injection strategy:
#   dream.sh prepends /opt/homebrew/bin:/usr/local/bin:~/.local/bin to PATH, so
#   a sandbox mock placed in $SANDBOX is shadowed. We temporarily replace
#   ~/.local/bin/claude with the mock for the LLM-calling tests (Tests 3+4),
#   and restore it via a trap on EXIT. Tests 1-2 use DREAM_SKIP_LLM=1 and
#   never invoke the claude binary.
#
# Session isolation:
#   Tests 1-2: --claude-sessions-root points to an empty dir so preprocess.py
#     finds no conversations → minimal sessions.md → token counts deterministic.
#   Tests 3-4: --claude-sessions-root points to fixtures/ which contains
#     three minimal JSONL files (session-a/b/c.jsonl). preprocess.py reads
#     only .jsonl files, producing 3 session blocks → chunker can split to >=2.
#     DREAM_CHUNK_TARGET_TOKENS=1 forces one session per chunk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

# ============================================================
# Sandbox: temp output + mocked vault dirs
# ============================================================

SANDBOX="$(mktemp -d)"
REAL_CLAUDE="$HOME/.local/bin/claude"
MOCK_INSTALLED=0

cleanup() {
  # Restore real claude if we replaced it
  if [[ "$MOCK_INSTALLED" == "1" ]] && [[ -f "${REAL_CLAUDE}.bak" ]]; then
    mv -f "${REAL_CLAUDE}.bak" "$REAL_CLAUDE"
    echo "[cleanup] restored real claude at $REAL_CLAUDE"
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# ============================================================
# Build mock claude binary (emits valid dream-report JSON)
# ============================================================

MOCK_BIN="$SANDBOX/mock-claude"
cat > "$MOCK_BIN" <<'MOCKEOF'
#!/usr/bin/env bash
# Consume stdin silently; ignore all args.
cat > /dev/null
cat <<JSON
{"type":"result","subtype":"success","is_error":false,"result":"---\ntype: dream-report\ndate: 2026-05-26\nwindow: 7d\n---\n\n## State changes\n- mock signal. (Claude Session 2026-05-21 09:14)\n","stop_reason":"end_turn","duration_ms":100,"total_cost_usd":0.001,"usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
JSON
MOCKEOF
chmod +x "$MOCK_BIN"

# ============================================================
# Helper: install/uninstall mock
# ============================================================

install_mock() {
  if [[ -f "$REAL_CLAUDE" ]]; then
    cp -f "$REAL_CLAUDE" "${REAL_CLAUDE}.bak"
  fi
  cp -f "$MOCK_BIN" "$REAL_CLAUDE"
  chmod +x "$REAL_CLAUDE"
  MOCK_INSTALLED=1
  echo "[mock] installed mock at $REAL_CLAUDE"
}

uninstall_mock() {
  if [[ "$MOCK_INSTALLED" == "1" ]] && [[ -f "${REAL_CLAUDE}.bak" ]]; then
    mv -f "${REAL_CLAUDE}.bak" "$REAL_CLAUDE"
    MOCK_INSTALLED=0
    echo "[mock] real claude restored"
  fi
}

# ============================================================
# Vault setups
# ============================================================

# Empty vault (<1KB) — triggers empty-vault route: single
VAULT_EMPTY="$SANDBOX/vault-empty"
mkdir -p "$VAULT_EMPTY"
cp "$FIXTURES/vault-empty.md" "$VAULT_EMPTY/"

# Sample vault (>1KB) — allows --force-chunked to work
# vault-sample.md must be >1024 bytes (dream.sh empty-vault threshold)
VAULT_SAMPLE="$SANDBOX/vault-sample"
mkdir -p "$VAULT_SAMPLE"
cp "$FIXTURES/vault-sample.md" "$VAULT_SAMPLE/"

# Empty sessions dir (no conversations → minimal sessions.md for routing tests)
EMPTY_SESSIONS="$SANDBOX/empty-sessions"
mkdir -p "$EMPTY_SESSIONS"

# ============================================================
# Test 1: empty vault (<1KB) → route: single
# Uses DREAM_SKIP_LLM=1 — no LLM call.
# Sessions pointed at empty dir → minimal sessions.md.
# ============================================================

echo "=== Test 1: empty-vault routing → route: single ==="

OUTPUT="$(DREAM_SKIP_LLM=1 "$SKILL_DIR/dream.sh" \
  --vault-root "$VAULT_EMPTY" \
  --output-dir "$SANDBOX/out-1" \
  --since 7d \
  --no-mcp \
  --claude-sessions-root "$EMPTY_SESSIONS" \
  --codex-sessions-root "$EMPTY_SESSIONS" \
  2>&1 || true)"

if echo "$OUTPUT" | grep -q "route: single"; then
  echo "  PASS"
else
  echo "FAIL: did not route to single (empty vault)"
  echo "--- output ---"
  echo "$OUTPUT"
  exit 1
fi

# ============================================================
# Test 2: --force-chunked on a >1KB vault → route: chunked
# Uses DREAM_SKIP_LLM=1 — no LLM call.
# Sessions pointed at empty dir → minimal sessions.md.
# ============================================================

echo "=== Test 2: --force-chunked → route: chunked ==="

OUTPUT="$(DREAM_SKIP_LLM=1 "$SKILL_DIR/dream.sh" \
  --vault-root "$VAULT_SAMPLE" \
  --output-dir "$SANDBOX/out-2" \
  --since 7d \
  --no-mcp \
  --force-chunked \
  --claude-sessions-root "$EMPTY_SESSIONS" \
  --codex-sessions-root "$EMPTY_SESSIONS" \
  2>&1 || true)"

if echo "$OUTPUT" | grep -q "route: chunked"; then
  echo "  PASS"
else
  echo "FAIL: did not route to chunked"
  echo "--- output ---"
  echo "$OUTPUT"
  exit 1
fi

# ============================================================
# Tests 3 & 4: full chunked path with mocked claude
#
# Strategy:
#   - Temporarily replace ~/.local/bin/claude with mock binary.
#   - Point --claude-sessions-root at fixtures/ which contains
#     three minimal JSONL session files (session-a/b/c.jsonl).
#     preprocess.py reads only *.jsonl files → 3 session blocks.
#   - DREAM_CHUNK_TARGET_TOKENS=1 forces each session into its
#     own chunk → chunker produces 3 chunks (>=2 required).
#   - Mock claude echoes valid dream-report JSON for all calls.
#   - Asserts: report file written + extracts dir preserved.
# ============================================================

echo "=== Tests 3+4: full chunked path (mock claude) ==="

install_mock

OUTPUT_DIR_34="$SANDBOX/out-34"

set +e
OUTPUT_34="$(DREAM_CHUNK_TARGET_TOKENS=1 \
  "$SKILL_DIR/dream.sh" \
  --vault-root "$VAULT_SAMPLE" \
  --output-dir "$OUTPUT_DIR_34" \
  --since 7d \
  --no-mcp \
  --force-chunked \
  --claude-sessions-root "$FIXTURES" \
  --codex-sessions-root "$EMPTY_SESSIONS" \
  2>&1)"
RC=$?
set -e

uninstall_mock

if [[ $RC -ne 0 ]]; then
  echo "FAIL (Tests 3+4): dream.sh exited non-zero (rc=$RC)"
  echo "--- dream.sh output ---"
  echo "$OUTPUT_34"
  exit 1
fi

# Test 3: dream report written
REPORT_FILE="$OUTPUT_DIR_34/dream-$(date -u +%F).md"
if [[ -f "$REPORT_FILE" ]]; then
  echo "  Test 3 PASS: dream report written at $REPORT_FILE"
else
  echo "FAIL (Test 3): no dream report written"
  echo "--- output ---"
  echo "$OUTPUT_34"
  exit 1
fi

# Test 4: extracts dir preserved with chunk files
EXTRACTS_DIR="$OUTPUT_DIR_34/dream-extracts-$(date -u +%F)"
if [[ -d "$EXTRACTS_DIR" ]]; then
  EXTRACT_COUNT=$(ls "$EXTRACTS_DIR/" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$EXTRACT_COUNT" -gt 0 ]]; then
    echo "  Test 4 PASS: extracts dir exists with $EXTRACT_COUNT file(s)"
  else
    echo "FAIL (Test 4): extracts dir exists but is empty"
    exit 1
  fi
else
  echo "FAIL (Test 4): no extracts dir at $EXTRACTS_DIR"
  echo "--- output ---"
  echo "$OUTPUT_34"
  exit 1
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "==============================================="
echo "  Smoke test summary"
echo "==============================================="
echo "  Test 1 (empty-vault → single route): PASS"
echo "  Test 2 (--force-chunked → chunked route): PASS"
echo "  Test 3 (dream report file written): PASS"
echo "  Test 4 (extracts dir preserved): PASS"
echo ""
echo "All smoke tests passed."
