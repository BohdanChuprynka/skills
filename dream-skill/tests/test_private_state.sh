#!/usr/bin/env bash
# Test: private-state.sh — resolves a chat's private (ignore) state from its
# transcript. Latest-wins. Must detect a GENUINE typed `/dream-skill --ignore`
# (string-content user record) while ignoring chats that merely quote/echo the
# serialization (tool_result arrays, assistant messages) — the false-positive
# guard that keeps the feature from marking unrelated chats private.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS="$SCRIPT_DIR/../scripts/private-state.sh"

[ -x "$PS" ] || { echo "FAIL: private-state.sh missing or not executable at $PS"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

WORK="$(mktemp -d /tmp/dream-ps-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Realistic records. Verified real serialization: a typed slash command is a
# user-role record whose STRING content holds the command block.
NORMAL_USER='{"type":"user","message":{"role":"user","content":"can we talk through something personal"}}'
ASSISTANT='{"type":"assistant","message":{"role":"assistant","content":"of course, go ahead"}}'
cmd_record() { # $1 = flag, e.g. --ignore / --unignore
  printf '{"type":"user","message":{"role":"user","content":"<command-message>dream-skill</command-message>\\n<command-name>/dream-skill</command-name>\\n<command-args>%s</command-args>"}}\n' "$1"
}
state_of() { "$PS" "$1"; }

# === Case 1: normal chat, no toggle → record ===
T="$WORK/c1.jsonl"; { echo "$NORMAL_USER"; echo "$ASSISTANT"; } > "$T"
[ "$(state_of "$T")" = "record" ] || fail "normal chat should be 'record', got '$(state_of "$T")'"
echo "PASS: no toggle → record"

# === Case 2: /dream-skill --ignore → ignore ===
T="$WORK/c2.jsonl"; { echo "$NORMAL_USER"; cmd_record "--ignore"; } > "$T"
[ "$(state_of "$T")" = "ignore" ] || fail "--ignore should be 'ignore', got '$(state_of "$T")'"
echo "PASS: --ignore → ignore"

# === Case 3: --ignore then later --unignore → record (latest wins) ===
T="$WORK/c3.jsonl"; { echo "$NORMAL_USER"; cmd_record "--ignore"; echo "$ASSISTANT"; cmd_record "--unignore"; } > "$T"
[ "$(state_of "$T")" = "record" ] || fail "ignore→unignore should be 'record', got '$(state_of "$T")'"
echo "PASS: --ignore then --unignore → record (latest wins)"

# === Case 4: --unignore then later --ignore → ignore (latest wins) ===
T="$WORK/c4.jsonl"; { cmd_record "--unignore"; echo "$ASSISTANT"; cmd_record "--ignore"; } > "$T"
[ "$(state_of "$T")" = "ignore" ] || fail "unignore→ignore should be 'ignore', got '$(state_of "$T")'"
echo "PASS: --unignore then --ignore → ignore (latest wins)"

# === Case 5: --unignore only (no prior ignore) → record ===
T="$WORK/c5.jsonl"; { echo "$NORMAL_USER"; cmd_record "--unignore"; } > "$T"
[ "$(state_of "$T")" = "record" ] || fail "lone --unignore should be 'record', got '$(state_of "$T")'"
echo "PASS: lone --unignore → record"

# === Case 6: serialization inside a tool_result ARRAY must NOT match ===
# Reading the spec/fixtures lands as a tool_result (array content), not a typed command.
T="$WORK/c6.jsonl"; printf '%s\n' "$NORMAL_USER" > "$T"
printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"file shows <command-name>/dream-skill</command-name>\\n<command-args>--ignore</command-args> as the marker"}]}}\n' >> "$T"
[ "$(state_of "$T")" = "record" ] || fail "tool_result quoting serialization must be 'record', got '$(state_of "$T")'"
echo "PASS: tool_result array quoting serialization → record (false-positive guard)"

# === Case 7: serialization inside an ASSISTANT message must NOT match ===
T="$WORK/c7.jsonl"; printf '%s\n' "$NORMAL_USER" > "$T"
printf '{"type":"assistant","message":{"role":"assistant","content":"to ignore, type <command-name>/dream-skill</command-name> with <command-args>--ignore</command-args>"}}\n' >> "$T"
[ "$(state_of "$T")" = "record" ] || fail "assistant message quoting serialization must be 'record', got '$(state_of "$T")'"
echo "PASS: assistant message quoting serialization → record (false-positive guard)"

# === Case 8: missing transcript → record (safe default; never crash) ===
[ "$(state_of "$WORK/does-not-exist.jsonl")" = "record" ] || fail "missing transcript should be 'record'"
echo "PASS: missing transcript → record"

# === Case 9: flat-shape ignore record also detected ===
T="$WORK/c9.jsonl"
printf '{"role":"user","content":"<command-message>dream-skill</command-message>\\n<command-name>/dream-skill</command-name>\\n<command-args>--ignore</command-args>"}\n' > "$T"
[ "$(state_of "$T")" = "ignore" ] || fail "flat-shape --ignore should be 'ignore', got '$(state_of "$T")'"
echo "PASS: flat-shape --ignore → ignore"

# === Case 10: Codex text invocation --ignore → ignore ===
T="$WORK/c10.jsonl"
cat > "$T" <<'EOF'
{"timestamp":"2026-07-01T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"Use $dream-skill --ignore"}}
EOF
[ "$(state_of "$T")" = "ignore" ] || fail "Codex Use \$dream-skill --ignore should be 'ignore', got '$(state_of "$T")'"
echo "PASS: Codex Use \$dream-skill --ignore → ignore"

# === Case 11: Codex latest-wins --ignore then --unignore → record ===
T="$WORK/c11.jsonl"
cat > "$T" <<'EOF'
{"timestamp":"2026-07-01T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"Use $dream-skill --ignore"}}
{"timestamp":"2026-07-01T00:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"Marked private."}}
{"timestamp":"2026-07-01T00:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"/dream-skill --unignore"}}
EOF
[ "$(state_of "$T")" = "record" ] || fail "Codex ignore→unignore should be 'record', got '$(state_of "$T")'"
echo "PASS: Codex --ignore then --unignore → record (latest wins)"

# === Case 12: Codex assistant/tool output quoting command must NOT match ===
T="$WORK/c12.jsonl"
cat > "$T" <<'EOF'
{"timestamp":"2026-07-01T00:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"To skip, say Use $dream-skill --ignore."}}
{"timestamp":"2026-07-01T00:00:01Z","type":"response_item","payload":{"type":"function_call_output","output":"Use $dream-skill --ignore"}}
EOF
[ "$(state_of "$T")" = "record" ] || fail "Codex assistant/tool quoting command should be 'record', got '$(state_of "$T")'"
echo "PASS: Codex assistant/tool quoting invocation → record"

echo
echo "All private-state.sh tests passed."
