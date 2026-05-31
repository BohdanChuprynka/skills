#!/usr/bin/env bash
# Test: report.sh — vault progress entries, best-effort, burst-safe
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="$SCRIPT_DIR/../scripts/report.sh"
[ -x "$REPORT" ] || { echo "FAIL: report.sh missing or not executable at $REPORT"; exit 1; }

RD="$(mktemp -d /tmp/dream-reports-test-XXXXXX)"
export DREAM_ERROR_LOG="$RD/error.log"
export DREAM_REPORTS_DIR="$RD"   # safety net: never fall through to the real vault config
trap 'rm -rf "$RD"' EXIT
fail() { echo "FAIL: $*"; echo "--- file ---"; cat "$RD"/dream-*.md 2>/dev/null; exit 1; }
DATE="$(date +%Y-%m-%d)"
FILE="$RD/dream-$DATE.md"

# Case 1: first write creates file with frontmatter + H1
"$REPORT" --status skipped --chat "abc12345 (Obsidian)" --reason "below-threshold (0 user messages)" --reports-dir "$RD"
grep -q "^type: dream-activity-log$" "$FILE" || fail "no frontmatter type"
grep -q "^# Dream activity — $DATE$" "$FILE" || fail "no H1 header"
grep -q "^### .* — skipped$" "$FILE" || fail "no skipped header"
grep -q "^reason: below-threshold (0 user messages)$" "$FILE" || fail "no reason line"
echo "PASS: first write creates file + skipped entry"

# Case 2: wrote — header count == [WRITE] lines on stdin, contents block present
printf -- '- [WRITE] me/wiki/x.md: a\n- [WRITE] me/wiki/y.md: b\n- [DROP] noise\n' \
  | "$REPORT" --status wrote --chat "def67890 (Obsidian)" --reports-dir "$RD"
grep -q "^### .* — wrote 2$" "$FILE" || fail "wrote header count wrong"
grep -q "^contents:$" "$FILE" || fail "no contents block"
grep -q "^- \[DROP\] noise$" "$FILE" || fail "drop line not preserved"
echo "PASS: wrote entry counts [WRITE] lines and keeps body"

# Case 3: noop
"$REPORT" --status noop --chat "self-ref" --reason "recursive-meta (no persona signal)" --reports-dir "$RD"
grep -q "^### .* — ran, 0 writes$" "$FILE" || fail "no noop header"
echo "PASS: noop entry"

# Case 4: error
"$REPORT" --status error --chat "b419 (Obsidian)" --reason "see error.log" --reports-dir "$RD"
grep -q "^### .* — error$" "$FILE" || fail "no error header"
echo "PASS: error entry"

# Case 5: best-effort — unwritable reports dir → exit 0, no crash
BLOCK="$RD/blockfile"; : > "$BLOCK"   # a regular file; cannot become a dir
"$REPORT" --status skipped --chat "x" --reason "y" --reports-dir "$BLOCK/sub"; rc=$?
[ "$rc" -eq 0 ] || fail "unwritable dir did not exit 0 (rc=$rc)"
echo "PASS: unwritable reports dir exits 0"

# Case 6: missing --status → exit 0 (best-effort)
"$REPORT" --chat "x" --reports-dir "$RD"; [ $? -eq 0 ] || fail "missing --status did not exit 0"
echo "PASS: missing --status exits 0"

# Case 7: concurrent appends — both land intact (atomic O_APPEND)
RD2="$(mktemp -d /tmp/dream-reports-conc-XXXXXX)"
F2="$RD2/dream-$DATE.md"
"$REPORT" --status noop --chat "aaa" --reason "first"  --reports-dir "$RD2" &
"$REPORT" --status noop --chat "bbb" --reason "second" --reports-dir "$RD2" &
wait
grep -q "^chat: aaa$" "$F2" || fail "concurrent: first entry missing"
grep -q "^chat: bbb$" "$F2" || fail "concurrent: second entry missing"
[ "$(grep -c '^### ' "$F2")" -eq 2 ] || fail "concurrent: expected 2 entries"
rm -rf "$RD2"
echo "PASS: concurrent appends both land"

# Case 8: --title emits a title: line directly under chat:
"$REPORT" --status skipped --chat "zzz (Obsidian)" --title "can you check the dream skill" --reason "below-threshold (0 user messages)" --reports-dir "$RD"
grep -q "^title: can you check the dream skill$" "$FILE" || fail "no title line for --title"
grep -A2 "^chat: zzz" "$FILE" | grep -q "^title: can you check" || fail "title not directly under chat"
echo "PASS: --title emits a title line under chat"

# Case 9: no --title → no title line for that entry
"$REPORT" --status noop --chat "notitle" --reason "x" --reports-dir "$RD"
line_after="$(grep -A1 "^chat: notitle$" "$FILE" | tail -1)"
case "$line_after" in title:*) fail "unexpected title line when --title omitted";; esac
echo "PASS: no title line when --title omitted"

echo
echo "All report.sh tests passed."
