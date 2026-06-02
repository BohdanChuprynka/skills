#!/usr/bin/env bash
# Test: trigger.sh threshold gating + dedupe lock + stdin/env paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
TRIGGER="$SCRIPT_DIR/../scripts/trigger.sh"

[ -x "$TRIGGER" ] || { echo "FAIL: trigger.sh missing or not executable at $TRIGGER"; exit 1; }

# Isolate test state. DREAM_REPORTS_DIR MUST be set: otherwise report.sh (called
# by trigger.sh on skip branches) falls through to the real config and writes
# into the user's actual vault. Per-case overrides still win for the cases that
# assert on a specific reports dir.
export DREAM_DISPATCH_STUB=1
export DREAM_LOG=/tmp/dream-test-trigger-$$.log
export DREAM_LOCK_DIR=/tmp/dream-test-locks-$$
export DREAM_REPORTS_DIR=/tmp/dream-test-reports-$$
trap 'rm -rf "$DREAM_LOG" "$DREAM_LOCK_DIR" "$DREAM_REPORTS_DIR"' EXIT
rm -rf "$DREAM_LOG" "$DREAM_LOCK_DIR" "$DREAM_REPORTS_DIR"

fail() { echo "FAIL: $*"; echo "--- log was ---"; cat "$DREAM_LOG" 2>/dev/null; exit 1; }
reset_log() { rm -f "$DREAM_LOG"; rm -rf "$DREAM_LOCK_DIR"; mkdir -p "$DREAM_LOCK_DIR"; }

# === Case 1: explicit high threshold gates a small session (mechanism test) ===
reset_log
DREAM_THRESHOLD=5 CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-3msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "3-msg fixture dispatched under threshold=5"
grep -q "below-threshold" "$DREAM_LOG" 2>/dev/null || fail "3-msg fixture did not log below-threshold at threshold=5"
echo "PASS: threshold=5 gates a 3-message session (below-threshold)"

# === Case 1b: default threshold (1) dispatches any session with >=1 user message ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-3msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "3-msg fixture did not dispatch under default threshold"
echo "PASS: default threshold dispatches a 3-message session"

# === Case 1c: floor — 0 user messages skips even at default threshold ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-0msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "0-user-msg fixture triggered DISPATCH"
grep -q "below-threshold" "$DREAM_LOG" 2>/dev/null || fail "0-user-msg fixture did not log below-threshold"
echo "PASS: 0-user-message session skipped (below-threshold floor)"

# === Case 2: 15-msg fixture → DISPATCH ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "15-msg fixture did not dispatch"
echo "PASS: 15-message fixture dispatched"

# === Case 3: empty path → SKIP no-path-provided ===
reset_log
CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER" < /dev/null
grep -q "no-path-provided" "$DREAM_LOG" 2>/dev/null || fail "empty path did not log no-path-provided"
echo "PASS: empty path → no-path-provided"

# === Case 4: nonexistent file → SKIP file-not-found (distinct from no-path) ===
reset_log
CLAUDE_TRANSCRIPT_PATH="/tmp/nonexistent-$$.jsonl" "$TRIGGER"
grep -q "file-not-found" "$DREAM_LOG" 2>/dev/null || fail "nonexistent file did not log file-not-found"
echo "PASS: nonexistent file → file-not-found"

# === Case 5: stdin JSON path triggers dispatch ===
reset_log
echo "{\"session_id\":\"test\",\"transcript_path\":\"$FIXTURE_DIR/transcript-15msg.jsonl\",\"cwd\":\"/tmp\",\"reason\":\"exit\"}" \
  | CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "stdin-JSON did not dispatch"
echo "PASS: stdin-JSON dispatches"

# === Case 6: re-closing the same chat with no new messages is suppressed ===
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
DISPATCH_COUNT=$(grep -c "DISPATCH" "$DREAM_LOG" 2>/dev/null || echo 0)
[ "$DISPATCH_COUNT" -eq 1 ] || fail "first call should DISPATCH once, got $DISPATCH_COUNT"

CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
DISPATCH_COUNT_AFTER=$(grep -c "DISPATCH" "$DREAM_LOG" 2>/dev/null || echo 0)
[ "$DISPATCH_COUNT_AFTER" -eq 1 ] || fail "second identical close re-dispatched (count=$DISPATCH_COUNT_AFTER, expected 1)"

grep -q "no-new-messages" "$DREAM_LOG" 2>/dev/null || fail "second identical close did not log no-new-messages"
echo "PASS: re-close with no new messages is suppressed (count-delta)"

# === Case 7: count-delta — re-dispatch only when new messages appear ===
reset_log
TMPD7="$(mktemp -d /tmp/dream-delta7-XXXXXX)"; TMPT7="$TMPD7/conv.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"one"}}' > "$TMPT7"
CLAUDE_TRANSCRIPT_PATH="$TMPT7" "$TRIGGER"                                 # count 1 > prev 0 -> dispatch
CLAUDE_TRANSCRIPT_PATH="$TMPT7" "$TRIGGER"                                 # count 1 == prev 1 -> skip
printf '%s\n' '{"type":"user","message":{"role":"user","content":"two"}}' >> "$TMPT7"
CLAUDE_TRANSCRIPT_PATH="$TMPT7" "$TRIGGER"                                 # count 2 > prev 1 -> dispatch
DCOUNT=$(grep -c "DISPATCH" "$DREAM_LOG" 2>/dev/null || echo 0)
[ "$DCOUNT" -eq 2 ] || fail "count-delta: expected 2 dispatches (initial + after new msg), got $DCOUNT"
grep -q "no-new-messages" "$DREAM_LOG" 2>/dev/null || fail "count-delta: unchanged close did not log no-new-messages"
rm -rf "$TMPD7"
echo "PASS: count-delta re-dispatches only on new messages"

# === Case 8: reason=clear → SKIP ===
reset_log
echo "{\"transcript_path\":\"$FIXTURE_DIR/transcript-15msg.jsonl\",\"reason\":\"clear\"}" \
  | CLAUDE_TRANSCRIPT_PATH="" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "reason=clear triggered dispatch"
grep -q "reason=clear" "$DREAM_LOG" 2>/dev/null || fail "reason=clear not logged"
echo "PASS: reason=clear skipped"

# === Case 9: claude-p exit code captured by wrapper ===
# Override `claude` with a stub that exits with code 7. Wrapper should log ERROR.
reset_log
STUB_DIR=$(mktemp -d "/tmp/dream-claude-stub-XXXXXX")
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$STUB_DIR/claude"

# Disable stub mode so real spawn-wrapper runs (against our fake claude)
unset DREAM_DISPATCH_STUB || true
PATH="$STUB_DIR:$PATH" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"

# Wait briefly for background wrapper (stub exits immediately, but log
# append happens after disown → poll up to 3s)
for i in 1 2 3 4 5 6; do
  grep -q "ERROR source=claude-p code=7" "$DREAM_LOG" 2>/dev/null && break
  sleep 0.5
done

grep -q "ERROR source=claude-p code=7" "$DREAM_LOG" \
  || fail "wrapper did not log ERROR for claude-p exit 7"
echo "PASS: wrapper captures claude-p non-zero exit + logs ERROR"

# Cleanup + restore stub mode for any future cases
rm -rf "$STUB_DIR"
export DREAM_DISPATCH_STUB=1

# === Case 10: compaction-continuation → resolve to live root + DISPATCH ===
# A continued conversation's SessionEnd fires with <uuid>.jsonl that never
# materializes; Claude Code keeps appending the content to the ROOT .jsonl
# (which references the continuation uuid). trigger.sh must recover the root.
reset_log
PROJ10=$(mktemp -d "/tmp/dream-proj10-XXXXXX")
CONT10="aaaaaaaa-1111-2222-3333-444444444444"
mkdir -p "$PROJ10/$CONT10/tool-results"   # compaction signature: sibling dir, no .jsonl
ROOT10="$PROJ10/99990000-0000-0000-0000-000000000000.jsonl"
cp "$FIXTURE_DIR/transcript-15msg.jsonl" "$ROOT10"
echo "{\"type\":\"attachment\",\"sessionId\":\"99990000-0000-0000-0000-000000000000\",\"ref\":\"$PROJ10/$CONT10/tool-results/x.txt\"}" >> "$ROOT10"
CLAUDE_TRANSCRIPT_PATH="$PROJ10/$CONT10.jsonl" "$TRIGGER"
grep -q "RESOLVED continuation=$CONT10" "$DREAM_LOG" 2>/dev/null || fail "compaction-continuation not resolved to root"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "resolved root did not dispatch"
rm -rf "$PROJ10"
echo "PASS: compaction-continuation resolves to live root and dispatches"

# === Case 11: sibling dir but NO root references the uuid → SKIP (linkage guard) ===
# Prevents grabbing an unrelated concurrent transcript just because it is newest.
reset_log
PROJ11=$(mktemp -d "/tmp/dream-proj11-XXXXXX")
CONT11="bbbbbbbb-1111-2222-3333-444444444444"
mkdir -p "$PROJ11/$CONT11/tool-results"
cp "$FIXTURE_DIR/transcript-15msg.jsonl" "$PROJ11/unrelated.jsonl"   # recent, but no uuid reference
CLAUDE_TRANSCRIPT_PATH="$PROJ11/$CONT11.jsonl" "$TRIGGER"
grep -q "RESOLVED" "$DREAM_LOG" 2>/dev/null && fail "resolved despite no uuid linkage"
grep -q "file-not-found" "$DREAM_LOG" 2>/dev/null || fail "unlinked continuation did not skip file-not-found"
rm -rf "$PROJ11"
echo "PASS: continuation with no linked root → file-not-found (linkage guard)"

# === Case 12: linked root but stale mtime → SKIP (recency guard) ===
# A root referenced only incidentally long ago must not be mistaken for the
# live conversation that just compacted.
reset_log
PROJ12=$(mktemp -d "/tmp/dream-proj12-XXXXXX")
CONT12="cccccccc-1111-2222-3333-444444444444"
mkdir -p "$PROJ12/$CONT12/tool-results"
ROOT12="$PROJ12/12340000-0000-0000-0000-000000000000.jsonl"
cp "$FIXTURE_DIR/transcript-15msg.jsonl" "$ROOT12"
echo "incidental ref $CONT12" >> "$ROOT12"
touch -t 202001010000 "$ROOT12"   # backdate far beyond the recency window
CLAUDE_TRANSCRIPT_PATH="$PROJ12/$CONT12.jsonl" "$TRIGGER"
grep -q "RESOLVED" "$DREAM_LOG" 2>/dev/null && fail "resolved a stale root beyond recency window"
grep -q "file-not-found" "$DREAM_LOG" 2>/dev/null || fail "stale-root continuation did not skip"
rm -rf "$PROJ12"
echo "PASS: stale root beyond window → file-not-found (recency guard)"

# === Case 13: headless auto-run transcript → SKIP recursive-headless (signature) ===
# A headless `claude -p "/dream-skill --auto X"` run creates its OWN transcript,
# which begins with the injected SKILL.md. Its SessionEnd must NOT re-dispatch,
# or the system cascades (each run spawns the next) and burns model quota.
reset_log
HEADLESS13=$(mktemp "/tmp/dream-headless13-XXXXXX.jsonl")
printf '%s\n' \
  '{"role":"user","content":"Base directory for this skill: /x\n\n# dream-skill\n\nPersona-model sync for an Obsidian vault. Four modes:"}' \
  '{"role":"assistant","content":"running auto mode"}' > "$HEADLESS13"
CLAUDE_TRANSCRIPT_PATH="$HEADLESS13" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "headless transcript re-dispatched (cascade risk!)"
grep -q "recursive-headless" "$DREAM_LOG" 2>/dev/null || fail "headless transcript not skipped as recursive"
rm -f "$HEADLESS13"
echo "PASS: headless auto-run transcript skipped (recursive-headless signature)"

# === Case 14: DREAM_SKILL_HEADLESS env marker → SKIP recursive-headless ===
# Belt-and-suspenders: a spawned run's SessionEnd inherits this marker, so it is
# skipped even if the transcript signature check is ever evaded.
reset_log
DREAM_SKILL_HEADLESS=1 CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "env-marker run re-dispatched (cascade risk!)"
grep -q "recursive-headless reason=env-marker" "$DREAM_LOG" 2>/dev/null || fail "env-marker not honored"
echo "PASS: DREAM_SKILL_HEADLESS env marker skips (recursive-headless)"

# === Case 15: below-threshold skip writes a vault report entry ===
reset_log
RD15="$(mktemp -d /tmp/dream-trig-rep15-XXXXXX)"
DREAM_REPORTS_DIR="$RD15" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-0msg.jsonl" "$TRIGGER"
grep -q "^### .* — skipped$" "$RD15"/dream-*.md 2>/dev/null || fail "below-threshold skip wrote no vault entry"
grep -q "below-threshold" "$RD15"/dream-*.md 2>/dev/null || fail "vault entry missing below-threshold reason"
rm -rf "$RD15"
echo "PASS: below-threshold skip produces a vault report entry"

# === Case 16: successful dispatch writes NO vault entry (the skill owns that) ===
reset_log
RD16="$(mktemp -d /tmp/dream-trig-rep16-XXXXXX)"
DREAM_REPORTS_DIR="$RD16" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
[ -z "$(ls -A "$RD16" 2>/dev/null)" ] || fail "dispatch should not write a vault entry (skill does)"
rm -rf "$RD16"
echo "PASS: successful dispatch writes no vault entry"

# === Case 17: skip entry carries a title: line pulled from history.jsonl ===
reset_log
RD17="$(mktemp -d /tmp/dream-trig-rep17-XXXXXX)"
HIST17="$(mktemp /tmp/dream-hist17-XXXXXX)"
printf '%s\n' '{"sessionId":"transcript-0msg","display":"my opener prompt about dreams","project":"/x"}' > "$HIST17"
DREAM_REPORTS_DIR="$RD17" DREAM_HISTORY_FILE="$HIST17" \
  CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-0msg.jsonl" "$TRIGGER"
grep -q "^title: my opener prompt about dreams$" "$RD17"/dream-*.md 2>/dev/null \
  || fail "skip entry missing title pulled from history.jsonl"
rm -rf "$RD17" "$HIST17"
echo "PASS: skip entry carries title from history.jsonl"

# === Case 18: title skips paste/image placeholders, uses first real prompt ===
reset_log
RD18="$(mktemp -d /tmp/dream-trig-rep18-XXXXXX)"
HIST18="$(mktemp /tmp/dream-hist18-XXXXXX)"
{
  printf '%s\n' '{"sessionId":"transcript-0msg","display":"[Pasted text #1 +3 lines]"}'
  printf '%s\n' '{"sessionId":"transcript-0msg","display":"real opener after the paste"}'
} > "$HIST18"
DREAM_REPORTS_DIR="$RD18" DREAM_HISTORY_FILE="$HIST18" \
  CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-0msg.jsonl" "$TRIGGER"
grep -q "^title: real opener after the paste$" "$RD18"/dream-*.md 2>/dev/null \
  || fail "title did not skip the paste placeholder"
grep -q "Pasted text" "$RD18"/dream-*.md 2>/dev/null && fail "title used the paste placeholder"
rm -rf "$RD18" "$HIST18"
echo "PASS: title skips paste/image placeholders"

# === Case 19: count is GENUINE typed messages, not tool_results / meta / injections ===
# transcript-real-format carries role:user on 4 records, but only 2 are messages the
# user actually typed (1 is a tool_result, 1 an isMeta caveat). At threshold=3 the
# genuine count (2) must fall BELOW threshold and skip. The old grep-based count (4)
# would wrongly dispatch — so this pins the genuine-message-counting semantics.
reset_log
DREAM_THRESHOLD=3 CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-real-format.jsonl" "$TRIGGER"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "tool_result/meta records inflated count past threshold (dispatched)"
grep -q "below-threshold count=2 threshold=3" "$DREAM_LOG" 2>/dev/null \
  || fail "genuine count should be 2 (tool_result + isMeta excluded); got: $(grep below-threshold "$DREAM_LOG" 2>/dev/null | tail -1)"
echo "PASS: count uses genuine typed messages (excludes tool_results/meta/injections)"

# === Case 20: gate fires on count CHANGE, not just growth — heals a stale baseline ===
# The stored seen-count can end up in a different SCALE than the live counter (e.g.
# after the message-counting method changes, an old inflated count lingers). If the
# new genuine count is LOWER than the stored value, the chat must still re-dispatch
# once and re-baseline — not get stuck skipping forever. Gate compares != (not >),
# so 2 != 15 -> dispatch, then prev becomes 2 and 2 == 2 -> skip.
reset_log
TMPD20="$(mktemp -d /tmp/dream-delta20-XXXXXX)"; TMPT20="$TMPD20/conv.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"one"}}' \
  '{"type":"user","message":{"role":"user","content":"two"}}' > "$TMPT20"
if command -v shasum >/dev/null 2>&1; then
  HASH20=$(printf '%s' "$TMPT20" | shasum -a 1 | awk '{print $1}')
else
  HASH20=$(printf '%s' "$TMPT20" | cksum | awk '{print $1}')
fi
echo 15 > "$DREAM_LOCK_DIR/$HASH20"   # simulate a stale, higher baseline (old grep counter)
CLAUDE_TRANSCRIPT_PATH="$TMPT20" "$TRIGGER"                                # count 2 != prev 15 -> dispatch
grep -q "DISPATCH count=2 prev=15" "$DREAM_LOG" 2>/dev/null \
  || fail "lower-than-stale count did not re-dispatch (stuck-skip bug); got: $(grep -E 'DISPATCH|no-new' "$DREAM_LOG" | tail -1)"
CLAUDE_TRANSCRIPT_PATH="$TMPT20" "$TRIGGER"                                # now prev=2, count 2 == 2 -> skip
grep -q "no-new-messages count=2 prev=2" "$DREAM_LOG" 2>/dev/null \
  || fail "did not re-baseline to genuine count after heal"
rm -rf "$TMPD20"
echo "PASS: count change (incl. downward) heals stale baseline, then re-baselines"

# === Case 21: /dream-skill --ignore → SKIP private (no dispatch, titleless report) ===
# A typed `/dream-skill --ignore` marks the chat private. trigger.sh must skip
# dispatch BEFORE counting/spawning, log SKIP private, and write a skipped vault
# entry WITHOUT a title: line (the first message is itself sensitive).
reset_log
RD21="$(mktemp -d /tmp/dream-trig-priv21-XXXXXX)"
TPD21="$(mktemp -d /tmp/dream-priv21-XXXXXX)"; TP21="$TPD21/sess-priv21.jsonl"
HIST21="$(mktemp /tmp/dream-hist21-XXXXXX)"
printf '%s\n' '{"sessionId":"sess-priv21","display":"something private I typed"}' > "$HIST21"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"help me with a personal matter"}}'
  printf '{"type":"user","message":{"role":"user","content":"<command-message>dream-skill</command-message>\\n<command-name>/dream-skill</command-name>\\n<command-args>--ignore</command-args>"}}\n'
} > "$TP21"
DREAM_REPORTS_DIR="$RD21" DREAM_HISTORY_FILE="$HIST21" CLAUDE_TRANSCRIPT_PATH="$TP21" "$TRIGGER"
grep -q "SKIP private" "$DREAM_LOG" 2>/dev/null || fail "ignore chat did not log SKIP private"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null && fail "ignore chat dispatched (should skip private)"
grep -q "^### .* — skipped$" "$RD21"/dream-*.md 2>/dev/null || fail "ignore chat wrote no skipped vault entry"
grep -q "marked private" "$RD21"/dream-*.md 2>/dev/null || fail "ignore vault entry missing 'marked private' reason"
grep -q "^title:" "$RD21"/dream-*.md 2>/dev/null && fail "ignore vault entry leaked a title: line (first message is sensitive)"
rm -rf "$RD21" "$TPD21" "$HIST21"
echo "PASS: /dream-skill --ignore → SKIP private, no dispatch, titleless skipped report"

# === Case 22: --ignore then later --unignore → DISPATCH (latest-wins) ===
reset_log
TPD22="$(mktemp -d /tmp/dream-priv22-XXXXXX)"; TP22="$TPD22/sess-priv22.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"normal stuff worth recording"}}'
  printf '{"type":"user","message":{"role":"user","content":"<command-message>dream-skill</command-message>\\n<command-name>/dream-skill</command-name>\\n<command-args>--ignore</command-args>"}}\n'
  printf '{"type":"user","message":{"role":"user","content":"<command-message>dream-skill</command-message>\\n<command-name>/dream-skill</command-name>\\n<command-args>--unignore</command-args>"}}\n'
} > "$TP22"
CLAUDE_TRANSCRIPT_PATH="$TP22" "$TRIGGER"
grep -q "SKIP private" "$DREAM_LOG" 2>/dev/null && fail "unignored chat skipped as private (latest-wins broken)"
grep -q "DISPATCH" "$DREAM_LOG" 2>/dev/null || fail "unignored chat did not dispatch"
rm -rf "$TPD22"
echo "PASS: --ignore then --unignore → dispatches (latest-wins)"

# === Case 23: DISPATCH line carries a clean-content byte count (audit trail) ===
# So a future false "empty-transcript" is detectable even though the headless run
# uses --no-session-persistence: trigger.log says bytes=N, the daily log would say
# empty-transcript — a visible contradiction. bytes= must be > 0 for a rich
# transcript (the v0.2 bug silently skipped a 5.8 KB session as empty).
reset_log
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-real-format.jsonl" "$TRIGGER"
grep -qE "DISPATCH.*bytes=[1-9][0-9]*" "$DREAM_LOG" 2>/dev/null \
  || fail "DISPATCH did not record a non-zero clean-content byte count (bytes=)"
echo "PASS: DISPATCH records clean-content byte count (bytes=N audit trail)"

echo
echo "All trigger.sh tests passed."
