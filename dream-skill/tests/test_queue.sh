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

echo
echo "All queue.sh tests passed."
