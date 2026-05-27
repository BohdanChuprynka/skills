#!/usr/bin/env bash
# Test: queue.sh append + list + clear
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE="$SCRIPT_DIR/../scripts/queue.sh"

[ -x "$QUEUE" ] || { echo "FAIL: queue.sh missing or not executable"; exit 1; }

QUEUE_FILE=$(mktemp "/tmp/dream-queue-test-XXXXXX.md")
trap 'rm -f "$QUEUE_FILE"' EXIT

export DREAM_QUEUE_FILE="$QUEUE_FILE"
> "$QUEUE_FILE"

fail() { echo "FAIL: $*"; cat "$QUEUE_FILE" >&2; exit 1; }

# Test 1: append destructive entry
"$QUEUE" append \
  --bucket destructive \
  --title "Update employer" \
  --evidence "I moved to Acme last week" \
  --confidence medium \
  --target "me/wiki/Bio.md"

grep -q "## Destructive edits" "$QUEUE_FILE" || fail "destructive section missing"
grep -q "Update employer" "$QUEUE_FILE" || fail "title missing"
grep -q "I moved to Acme" "$QUEUE_FILE" || fail "evidence missing"
echo "PASS: append destructive entry"

# Test 2: append brainstormed entry
"$QUEUE" append \
  --bucket brainstormed \
  --title "Maybe pivot to agency" \
  --evidence "thinking about doing AI consulting" \
  --confidence low \
  --target "me/wiki/Career.md"

grep -q "## Brainstormed ideas" "$QUEUE_FILE" || fail "brainstormed section missing"
grep -q "Maybe pivot to agency" "$QUEUE_FILE" || fail "brainstorm title missing"
echo "PASS: append brainstormed entry"

# Test 3: append uncertain entry
"$QUEUE" append \
  --bucket uncertain \
  --title "Possible new project" \
  --evidence "mentioned briefly" \
  --confidence medium \
  --target "projects/wiki/new.md"

grep -q "## Uncertain facts" "$QUEUE_FILE" || fail "uncertain section missing"
echo "PASS: append uncertain entry"

# Test 4: list shows all 3 entries
OUT=$("$QUEUE" list)
echo "$OUT" | grep -q "Update employer" || fail "list missing destructive entry"
echo "$OUT" | grep -q "Maybe pivot to agency" || fail "list missing brainstorm"
echo "$OUT" | grep -q "Possible new project" || fail "list missing uncertain"
echo "PASS: list shows all entries"

# Test 5: bucket sections coexist correctly (no entry leaked into wrong section)
DEST_COUNT=$(grep -c "Update employer" "$QUEUE_FILE")
[ "$DEST_COUNT" -eq 1 ] || fail "destructive entry duplicated (count=$DEST_COUNT)"
echo "PASS: no cross-section duplication"

# Test 6: unknown bucket → error
if "$QUEUE" append --bucket nonsense --title t --evidence e --confidence low --target x 2>/dev/null; then
  fail "unknown bucket accepted"
fi
echo "PASS: unknown bucket rejected"

# Test 7: dedupe — same (title, target) appended twice should produce one entry
"$QUEUE" append \
  --bucket destructive \
  --title "Update employer" \
  --evidence "duplicate attempt" \
  --confidence medium \
  --target "me/wiki/Bio.md" 2>/dev/null

OCCURRENCES=$(grep -c "### Update employer" "$QUEUE_FILE")
[ "$OCCURRENCES" -eq 1 ] || fail "dedupe failed (count=$OCCURRENCES, expected 1)"
echo "PASS: dedupe — same title+target queued only once"

# Test 8: same title but different target → should NOT dedupe
"$QUEUE" append \
  --bucket destructive \
  --title "Update employer" \
  --evidence "different vault entry" \
  --confidence medium \
  --target "me/wiki/Work.md"

OCCURRENCES2=$(grep -c "### Update employer" "$QUEUE_FILE")
[ "$OCCURRENCES2" -eq 2 ] || fail "same title + different target wrongly deduped (count=$OCCURRENCES2)"
echo "PASS: same title, different target → both entries kept"

# Test 9: remove — removes ONLY the matching (title, target) entry
"$QUEUE" remove --title "Update employer" --target "me/wiki/Bio.md"
OCCURRENCES3=$(grep -c "### Update employer" "$QUEUE_FILE")
[ "$OCCURRENCES3" -eq 1 ] || fail "remove deleted wrong count (after=$OCCURRENCES3, expected 1)"
grep -q "me/wiki/Work.md" "$QUEUE_FILE" || fail "remove deleted the wrong target"
grep -q "me/wiki/Bio.md" "$QUEUE_FILE" && fail "remove did not delete me/wiki/Bio.md"
echo "PASS: remove deletes only matching title+target"

# Test 10: remove — non-matching pair returns error (rc != 0), queue untouched
LINES_BEFORE=$(wc -l < "$QUEUE_FILE")
if "$QUEUE" remove --title "Nonexistent" --target "nowhere/page.md" 2>/dev/null; then
  fail "remove of non-matching entry should have errored"
fi
LINES_AFTER=$(wc -l < "$QUEUE_FILE")
[ "$LINES_BEFORE" -eq "$LINES_AFTER" ] || fail "queue was mutated despite no-match remove"
echo "PASS: remove of non-matching pair errors + leaves queue intact"

# Test 11: remove last entry → queue stays parseable (no stray section header artifacts)
"$QUEUE" remove --title "Maybe pivot to agency" --target "me/wiki/Career.md"
"$QUEUE" remove --title "Possible new project" --target "projects/wiki/new.md"
"$QUEUE" remove --title "Update employer" --target "me/wiki/Work.md"
# Re-append something to verify the queue still works after removals
"$QUEUE" append \
  --bucket uncertain \
  --title "post-removal sanity" \
  --evidence "verify queue still works" \
  --confidence low \
  --target "test/page.md"
grep -q "post-removal sanity" "$QUEUE_FILE" || fail "queue broken after batch removals"
echo "PASS: queue survives full drain + re-append"

echo
echo "All queue.sh tests passed."
