#!/usr/bin/env bash
# Unit tests for scripts/prefilter-transcript.py.
# The helper is the MAP-stage guard that converts raw Claude JSONL into compact
# USER/ASST text before any extraction agent reads a transcript.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PREFILTER="$ROOT/scripts/prefilter-transcript.py"

fail() { echo "FAIL: $*"; exit 1; }

[ -x "$PREFILTER" ] || fail "prefilter-transcript.py missing or not executable"

TMPROOT=$(mktemp -d "/tmp/dream-prefilter-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

assert_absent() {
  local file="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if rg -n --fixed-strings "$pattern" "$file" >/dev/null 2>&1; then
      rg -n --fixed-strings "$pattern" "$file" || true
      fail "blocked marker leaked into $(basename "$file"): $pattern"
    fi
  done
}

assert_only_role_lines() {
  local file="$1"
  if [ "$(wc -c < "$file")" -eq 0 ]; then
    return
  fi
  if ! awk '($0 !~ /^(USER|ASST): /) { bad=1 } END { exit bad }' "$file"; then
    fail "filtered output contains non role-prefixed lines: $file"
  fi
}

# Real Claude-format fixture: keeps human/assistant text, drops JSON plumbing.
REAL_OUT="$TMPROOT/real.out"
"$PREFILTER" "$SCRIPT_DIR/fixtures/transcript-real-format.jsonl" > "$REAL_OUT"
cat > "$TMPROOT/real.expected" <<'EOF'
USER: Help me plan tomorrow
ASST: Sure. Calendar shows 3 events.
USER: Schedule 9am block for project X.
ASST: Locked in 9am block for project X.
EOF
diff -u "$TMPROOT/real.expected" "$REAL_OUT" || fail "real-format filtered output mismatch"
assert_absent "$REAL_OUT" \
  "BIG_MCP_DATA_BLOB_REAL" \
  "tool_result" \
  "tool_use_id" \
  "tool_use" \
  "<system-reminder>" \
  "<local-command-caveat>" \
  "sessionId"
assert_only_role_lines "$REAL_OUT"
echo "PASS: real Claude-format transcript keeps only user/assistant text"

# Empty-clean fixture should emit literally zero bytes, not just command-substitution empty.
EMPTY_OUT="$TMPROOT/empty.out"
"$PREFILTER" "$SCRIPT_DIR/fixtures/transcript-empty-clean.jsonl" > "$EMPTY_OUT"
[ "$(wc -c < "$EMPTY_OUT")" -eq 0 ] || fail "empty-clean fixture should emit 0 bytes"
echo "PASS: metadata/tool-only transcript emits 0 bytes"

# Older simplified role/content rows are still supported.
NOISY_OUT="$TMPROOT/noisy.out"
"$PREFILTER" "$SCRIPT_DIR/fixtures/transcript-noisy.jsonl" > "$NOISY_OUT"
cat > "$TMPROOT/noisy.expected" <<'EOF'
USER: Help me plan tomorrow
ASST: Sure. Calendar shows 3 events.
USER: Schedule 9am block for project X.
ASST: Locked in 9am block for project X.
USER: Plain string content also works
ASST: And plain string assistant reply
EOF
diff -u "$TMPROOT/noisy.expected" "$NOISY_OUT" || fail "noisy filtered output mismatch"
assert_absent "$NOISY_OUT" "BIG_MCP_DATA_BLOB" "tool_result" "tool_use_id" "<system-reminder>"
assert_only_role_lines "$NOISY_OUT"
echo "PASS: simplified role/content transcript is filtered correctly"

# Mixed content arrays: keep text blocks in order, drop tool_result in the same array.
MIXED="$TMPROOT/mixed.jsonl"
cat > "$MIXED" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"I accepted the Cleveland Clinic sprint scope."},{"type":"tool_result","tool_use_id":"x","content":"MIXED_BLOB_SHOULD_DROP"},{"type":"text","text":"The deadline is June 14."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Noted."},{"type":"thinking","thinking":"MIXED_THINKING_SHOULD_DROP"},{"type":"tool_use","id":"y","name":"bash","input":{"cmd":"echo nope"}}]}}
EOF
MIXED_OUT="$TMPROOT/mixed.out"
"$PREFILTER" "$MIXED" > "$MIXED_OUT"
cat > "$TMPROOT/mixed.expected" <<'EOF'
USER: I accepted the Cleveland Clinic sprint scope.
The deadline is June 14.
ASST: Noted.
EOF
diff -u "$TMPROOT/mixed.expected" "$MIXED_OUT" || fail "mixed content-array output mismatch"
assert_absent "$MIXED_OUT" "MIXED_BLOB_SHOULD_DROP" "MIXED_THINKING_SHOULD_DROP" "tool_result" "tool_use"
echo "PASS: mixed text/tool arrays preserve text and drop plumbing"

# Command and context wrappers: pure wrappers drop, adjacent real user text remains.
WRAPPERS="$TMPROOT/wrappers.jsonl"
cat > "$WRAPPERS" <<'EOF'
{"type":"user","message":{"role":"user","content":"<command-message>dream private</command-message>\n<command-name>/dream-skill</command-name>\n<command-args>--ignore</command-args>"}}
{"type":"user","message":{"role":"user","content":"<system-reminder>noise before slash command</system-reminder><command-message>dream private</command-message>\n<command-name>/dream-skill</command-name>\n<command-args>--ignore</command-args>"}}
{"type":"user","message":{"role":"user","content":"<local-command-caveat>noise before slash command</local-command-caveat><command-message>dream private</command-message>\n<command-name>/dream-skill</command-name>\n<command-args>--unignore</command-args>"}}
{"type":"user","message":{"role":"user","content":"<local-command-caveat>do not include this</local-command-caveat>"}}
{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>origin task notification should drop</task-notification>"}}
{"type":"user","message":{"role":"user","content":"<task-notification>string wrapper task notification should drop</task-notification>"}}
{"type":"user","message":{"role":"user","content":"<system-reminder>first noisy reminder</system-reminder>I changed the default model to Sonnet.<system-reminder>\nsecond noisy reminder\n</system-reminder>"}}
{"type":"user","message":{"role":"user","content":"<ide_selection>SELECTED_CODE_SHOULD_DROP</ide_selection>Can you explain why this reducer matters?"}}
{"type":"assistant","message":{"role":"assistant","content":"Assistant quoting <command-args>--ignore</command-args> should stay as visible assistant text."}}
{"type":"user","message":{"role":"user","content":"User prose quoting <command-args>--ignore</command-args> should stay because it is not a pure command wrapper."}}
EOF
WRAP_OUT="$TMPROOT/wrappers.out"
"$PREFILTER" "$WRAPPERS" > "$WRAP_OUT"
cat > "$TMPROOT/wrappers.expected" <<'EOF'
USER: I changed the default model to Sonnet.
USER: Can you explain why this reducer matters?
ASST: Assistant quoting <command-args>--ignore</command-args> should stay as visible assistant text.
USER: User prose quoting <command-args>--ignore</command-args> should stay because it is not a pure command wrapper.
EOF
diff -u "$TMPROOT/wrappers.expected" "$WRAP_OUT" || fail "wrapper filtering output mismatch"
assert_absent "$WRAP_OUT" "SELECTED_CODE_SHOULD_DROP" "<system-reminder>" "<local-command-caveat>" "<command-message>" "<command-name>" "<task-notification>" "task notification should drop"
echo "PASS: command/system/context wrappers are handled without dropping adjacent prose"

# Corrupt/partial transcript: exit 0, skip bad rows, keep valid rows.
CORRUPT="$TMPROOT/corrupt.jsonl"
{
  printf 'not json first\n'
  printf '{"type":"user","message":{"role":"user","content":"valid middle"}}\n'
  printf '[1,2,3]\n'
  printf '{"type":"user","message":"not a dict"}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":{"unsupported":"shape"}}}\n'
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"valid array text"}]}}\n'
  printf '{"type":"user","message":{"role":"user","content":"huge truncated'
  dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\0' 'x'
} > "$CORRUPT"
CORRUPT_OUT="$TMPROOT/corrupt.out"
CORRUPT_ERR="$TMPROOT/corrupt.err"
rc=0
"$PREFILTER" "$CORRUPT" > "$CORRUPT_OUT" 2> "$CORRUPT_ERR" || rc=$?
[ "$rc" -eq 0 ] || fail "corrupt transcript should exit 0, got $rc"
cat > "$TMPROOT/corrupt.expected" <<'EOF'
USER: valid middle
USER: valid array text
EOF
diff -u "$TMPROOT/corrupt.expected" "$CORRUPT_OUT" || fail "corrupt transcript output mismatch"
echo "PASS: corrupt and partially flushed transcript exits 0"

# --stats must never pollute stdout; stdout should match normal mode byte-for-byte.
STATS_OUT="$TMPROOT/stats.out"
STATS_ERR="$TMPROOT/stats.err"
"$PREFILTER" --stats "$SCRIPT_DIR/fixtures/transcript-real-format.jsonl" > "$STATS_OUT" 2> "$STATS_ERR"
diff -u "$REAL_OUT" "$STATS_OUT" || fail "--stats changed stdout"
[ "$(wc -l < "$STATS_ERR")" -eq 1 ] || fail "--stats should emit exactly one stderr line"
grep -q "prefilter_stats" "$STATS_ERR" || fail "--stats stderr missing prefilter_stats marker"
assert_only_role_lines "$STATS_OUT"
echo "PASS: --stats writes summary to stderr only"

# Generated monster regression: most bytes are tool_result payload and must vanish.
MONSTER="$TMPROOT/monster.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"I decided the agency ICP is spine clinics."}}\n'
  for i in $(seq 1 60); do
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"' "$i"
    dd if=/dev/zero bs=65536 count=1 2>/dev/null | tr '\0' 'A'
    printf '"}]}}\n'
  done
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Captured."},{"type":"thinking","thinking":"SHOULD_NOT_LEAK"}]}}\n'
} > "$MONSTER"
MONSTER_OUT="$TMPROOT/monster.out"
"$PREFILTER" "$MONSTER" > "$MONSTER_OUT"
raw_bytes=$(wc -c < "$MONSTER")
filtered_bytes=$(wc -c < "$MONSTER_OUT")
[ "$filtered_bytes" -lt $((raw_bytes / 100)) ] \
  || fail "monster shrink too small: raw=$raw_bytes filtered=$filtered_bytes"
[ "$filtered_bytes" -lt 1000 ] || fail "monster filtered output unexpectedly large: $filtered_bytes bytes"
assert_absent "$MONSTER_OUT" "tool_result" "tool_use_id" "SHOULD_NOT_LEAK" "AAAAA" "<task-notification>"
echo "PASS: generated monster transcript drops tool payloads and shrinks >100x"

echo
echo "All prefilter-transcript tests passed."
