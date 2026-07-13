#!/usr/bin/env bash
# test_integration_smoke.sh — hermetic end-to-end smoke test (no model calls).
#
# Exercises the SHELL PLUMBING of FIND → (mock decisions) → APPLY(dry-run) → RECEIPT.
#
# Three focused assertions:
#   Part A: seed mock ~/.claude/projects dir + marker → find-chats.sh emits transcript path
#   Part B: apply-decision.sh --dry-run against mock vault → byte-identical, expected messages
#   Part C: write-receipt.sh fed mock run-summary JSON → receipt sections + index line

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DREAM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FIND_CHATS="$DREAM_DIR/scripts/find-chats.sh"
APPLY_DEC="$DREAM_DIR/scripts/apply-decision.sh"
WRITE_RECEIPT="$DREAM_DIR/scripts/write-receipt.sh"

for s in "$FIND_CHATS" "$APPLY_DEC" "$WRITE_RECEIPT"; do
  [ -x "$s" ] || { echo "FAIL: script missing or not executable: $s"; exit 1; }
done

fail() { echo "FAIL: $*"; exit 1; }

# ── global temp root (cleaned up on exit) ────────────────────────────────────
TMPROOT=$(mktemp -d "/tmp/dream-smoke-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# Helper: create a .jsonl file with explicit mtime N days ago (mirrors test_find_chats.sh)
make_chat() {
  local path="$1" days_ago="$2"
  mkdir -p "$(dirname "$path")"
  printf '{"role":"user","content":"hello"}\n' > "$path"
  local ts
  ts=$(date -v "-${days_ago}d" +%Y%m%d%H%M 2>/dev/null \
    || date --date="${days_ago} days ago" +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

# =============================================================================
# PART A: FIND
#   Seed a mock projects dir with a fixture transcript + a temp marker.
#   Run find-chats.sh. Assert it emits the transcript path.
# =============================================================================

PROJ_ROOT="$TMPROOT/projects"
MARKER_DIR="$TMPROOT/markers"
mkdir -p "$MARKER_DIR"

# Create a .jsonl transcript with mtime 1 day ago → inside the default 7-day window
TRANSCRIPT="$PROJ_ROOT/proj-alpha/chat.jsonl"
make_chat "$TRANSCRIPT" 1

FIND_OUT=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
           DREAM_MARKER_DIR="$MARKER_DIR" \
           "$FIND_CHATS" 2>/dev/null)

echo "$FIND_OUT" | grep -qF "chat.jsonl" \
  || fail "FIND: transcript path not emitted by find-chats.sh; output was: $FIND_OUT"
echo "$FIND_OUT" | grep -qE "^BATCH:" \
  || fail "FIND: no BATCH header in find-chats.sh output"

echo "PASS: FIND → find-chats.sh emits transcript path and BATCH header"

# Also assert an OLD chat (outside 7-day window) is NOT emitted
OLD_TRANSCRIPT="$PROJ_ROOT/proj-beta/old.jsonl"
make_chat "$OLD_TRANSCRIPT" 30

FIND_OUT2=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
            DREAM_MARKER_DIR="$MARKER_DIR" \
            "$FIND_CHATS" 2>/dev/null)

echo "$FIND_OUT2" | grep -qF "old.jsonl" \
  && fail "FIND: old chat (30 days ago) should not appear in 7-day window"

echo "PASS: FIND → old chat correctly excluded from default 7-day window"

# =============================================================================
# PART B: APPLY (dry-run)
#   Take mock reconciliation decisions (new + supersede) from fixtures.
#   Run apply-decision.sh --dry-run against a mock vault.
#   Assert vault is byte-identical (no writes) and expected dry-run messages appear.
# =============================================================================

# Build a minimal mock vault
VAULT="$TMPROOT/mock-vault"
mkdir -p "$VAULT/wiki"

# Page for the 'new' decision (Skills page)
cat > "$VAULT/wiki/skills.md" <<'EOF'
# Skills

## Languages

- Python (proficient)
- TypeScript (proficient)

## Frameworks

- React
- FastAPI
EOF

# Page for the 'supersede' decision (Bio page)
cat > "$VAULT/wiki/bio.md" <<'EOF'
# Bio

## Bio

- lives in Berlin
- originally from Kyiv
EOF

# Snapshot byte content before dry-run
SKILLS_BEFORE=$(cat "$VAULT/wiki/skills.md")
BIO_BEFORE=$(cat "$VAULT/wiki/bio.md")

UNDO_LOG="$TMPROOT/undo.jsonl"
QUEUE_FILE="$TMPROOT/review-queue.md"
export DREAM_QUEUE_FILE="$QUEUE_FILE"

# ── Part B1: 'new' decision, --dry-run ────────────────────────────────────────
# Decision JSON reuses the shape from tests/fixtures/reconcile/new.json
# (action=new, needs_review:false, high confidence → would append, no queue)
NEW_DEC="$TMPROOT/decision-new.json"
cat > "$NEW_DEC" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": {
    "vault": "me",
    "page": "wiki/skills.md",
    "section": "Certifications"
  },
  "content": "Passed AWS Solutions Architect exam 2026-05",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Fact is absent from the target page and candidate confidence is high."
}
EOF

NEW_DRY_OUT=$("$APPLY_DEC" \
  --vault    "$VAULT" \
  --decision "$NEW_DEC" \
  --undo-log "$UNDO_LOG" \
  --dry-run  2>&1)

# Vault must be byte-identical
SKILLS_AFTER=$(cat "$VAULT/wiki/skills.md")
[ "$SKILLS_BEFORE" = "$SKILLS_AFTER" ] \
  || fail "APPLY dry-run new: wiki/skills.md was mutated (not byte-identical)"

# Queue file must NOT have been created or written
[ ! -f "$QUEUE_FILE" ] \
  || [ "$(wc -c < "$QUEUE_FILE")" = "0" ] \
  || fail "APPLY dry-run new (no needs_review): queue file should remain empty"

# Dry-run message must mention vault-writer and mode=append
echo "$NEW_DRY_OUT" | grep -qi "vault-writer \[dry-run\]" \
  || fail "APPLY dry-run new: expected 'vault-writer [dry-run]' in output; got: $NEW_DRY_OUT"
echo "$NEW_DRY_OUT" | grep -qi "mode=append" \
  || fail "APPLY dry-run new: expected 'mode=append' in dry-run output"

echo "PASS: APPLY dry-run new → vault byte-identical, 'vault-writer [dry-run]' + mode=append present"

# ── Part B2: 'supersede' decision, --dry-run ─────────────────────────────────
# Decision JSON reuses shape from tests/fixtures/reconcile/supersede.json
# (action=supersede, needs_review:true → would replace + would queue)
SUP_DEC="$TMPROOT/decision-supersede.json"
cat > "$SUP_DEC" <<'EOF'
{
  "action": "supersede",
  "mode": "replace",
  "target": {
    "vault": "me",
    "page": "wiki/bio.md",
    "section": "Bio"
  },
  "old_content": "lives in Berlin",
  "content": "lives in Munich (moved 2026-06)",
  "candidate_confidence": "high",
  "needs_review": true,
  "rationale": "Candidate's source_date is newer; same subject+attribute (location)."
}
EOF

# Reset queue file state for this sub-test
rm -f "$QUEUE_FILE"

SUP_DRY_OUT=$("$APPLY_DEC" \
  --vault    "$VAULT" \
  --decision "$SUP_DEC" \
  --undo-log "$UNDO_LOG" \
  --dry-run  2>&1)

# Vault bio.md must be byte-identical
BIO_AFTER=$(cat "$VAULT/wiki/bio.md")
[ "$BIO_BEFORE" = "$BIO_AFTER" ] \
  || fail "APPLY dry-run supersede: wiki/bio.md was mutated (not byte-identical)"

# Queue file must NOT have been written
[ ! -f "$QUEUE_FILE" ] \
  || [ "$(wc -c < "$QUEUE_FILE")" = "0" ] \
  || fail "APPLY dry-run supersede: queue file should remain empty"

# Dry-run messages: vault-writer and would-queue
echo "$SUP_DRY_OUT" | grep -qi "vault-writer \[dry-run\]" \
  || fail "APPLY dry-run supersede: expected 'vault-writer [dry-run]' in output; got: $SUP_DRY_OUT"
echo "$SUP_DRY_OUT" | grep -qi "mode=replace" \
  || fail "APPLY dry-run supersede: expected 'mode=replace' in output"
echo "$SUP_DRY_OUT" | grep -qi "would queue" \
  || fail "APPLY dry-run supersede: expected 'would queue' in output"
echo "$SUP_DRY_OUT" | grep -qi "destructive" \
  || fail "APPLY dry-run supersede: expected 'destructive' bucket in output"

echo "PASS: APPLY dry-run supersede → vault byte-identical, 'vault-writer [dry-run]' + 'would queue' + 'destructive' present"

# =============================================================================
# PART C: RECEIPT
#   Run reconciliation-decision OBJECTS through apply-decision.sh --dry-run,
#   capture the emitted run-summary fact lines, assemble them into the
#   run-summary JSON, and feed that to write-receipt.sh.
#   This proves the object→string flatten works end-to-end.
# =============================================================================

RUNS_DIR="$TMPROOT/runs"
mkdir -p "$RUNS_DIR"

# Build a vault for Part C decisions (apply-decision --dry-run won't mutate it)
VAULT_C="$TMPROOT/vault-c"
mkdir -p "$VAULT_C/wiki"
cat > "$VAULT_C/wiki/skills.md" <<'EOF'
# Skills

## Certifications

- holds CKAD cert

## Languages

- Python (proficient)
EOF
cat > "$VAULT_C/wiki/bio.md" <<'EOF'
# Bio

## Bio

- lives in Berlin
- originally from Kyiv
EOF
cat > "$VAULT_C/wiki/projects.md" <<'EOF'
# Projects

## Work

- current internship at Aximon
EOF

UNDO_LOG_C="$TMPROOT/undo-c.jsonl"
QUEUE_FILE_C="$TMPROOT/queue-c.md"
export DREAM_QUEUE_FILE="$QUEUE_FILE_C"

# Helper: run one decision through apply-decision --dry-run, capture stdout fact lines
run_dec() {
  local dec_file="$1"
  "$APPLY_DEC" \
    --vault    "$VAULT_C" \
    --decision "$dec_file" \
    --undo-log "$UNDO_LOG_C" \
    --dry-run  2>/dev/null || true
}

# Decision 1: new (high confidence, no needs_review) → review_status=written
DEC1="$TMPROOT/dec1.json"
cat > "$DEC1" <<'EOF'
{
  "action": "new", "mode": "append",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "Passed AWS Solutions Architect exam 2026-05",
  "candidate_confidence": "high", "needs_review": false,
  "rationale": "Absent fact."
}
EOF

# Decision 2: supersede → review_status=written
DEC2="$TMPROOT/dec2.json"
cat > "$DEC2" <<'EOF'
{
  "action": "supersede", "mode": "replace",
  "target": { "vault": "me", "page": "wiki/bio.md", "section": "Bio" },
  "old_content": "lives in Berlin",
  "content": "lives in Munich (moved 2026-06)",
  "candidate_confidence": "high", "needs_review": true,
  "rationale": "Newer source_date."
}
EOF

# Decision 3: contradict → emits TWO facts (written-old + queued-new)
DEC3="$TMPROOT/dec3.json"
cat > "$DEC3" <<'EOF'
{
  "action": "contradict", "mode": "stale",
  "target": { "vault": "me", "page": "wiki/projects.md", "section": "Work" },
  "old_content": "current internship at Aximon",
  "content": "internship at Aximon ended",
  "candidate_confidence": "medium", "needs_review": true,
  "rationale": "Contradicts current state."
}
EOF

# Decision 4: duplicate → review_status=skipped
DEC4="$TMPROOT/dec4.json"
cat > "$DEC4" <<'EOF'
{
  "action": "duplicate", "mode": "none",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Languages" },
  "content": "Python 3.12",
  "candidate_confidence": "high", "needs_review": false,
  "rationale": "Already present."
}
EOF

# Run each decision through apply-decision --dry-run and collect fact lines
FACT_LINES=""
for dec in "$DEC1" "$DEC2" "$DEC3" "$DEC4"; do
  lines=$(run_dec "$dec")
  # Keep only lines that look like JSON objects (run-summary facts)
  json_lines=$(printf '%s\n' "$lines" | grep -E '^\{' || true)
  if [ -n "$json_lines" ]; then
    FACT_LINES=$(printf '%s\n%s' "$FACT_LINES" "$json_lines")
  fi
done

# Assert every emitted fact has a flattened (string) target
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ttype=$(printf '%s' "$line" | jq -r '.target | type' 2>/dev/null || echo "invalid")
  [ "$ttype" = "string" ] \
    || fail "RECEIPT seam: emitted fact has non-string .target (type=$ttype, line=$line)"
done <<< "$FACT_LINES"
echo "PASS: RECEIPT seam → all apply-decision --dry-run facts have flattened string target"

# Assemble the run-summary JSON from the collected fact lines
FACTS_JSON=$(printf '%s\n' "$FACT_LINES" | grep -E '^\{' | jq -s '.')
SUMMARY=$(jq -cn \
  --arg     run_id        "smoke-2026-06-04T00:00:00Z" \
  --arg     date          "2026-06-04" \
  --arg     window_start  "2026-05-28" \
  --arg     window_end    "2026-06-04" \
  --argjson chats_scanned 1 \
  --argjson facts         "$FACTS_JSON" \
  '{run_id:$run_id, date:$date, window_start:$window_start, window_end:$window_end, chats_scanned:$chats_scanned, facts:$facts}')

RECEIPT_OUT=$(printf '%s' "$SUMMARY" | DREAM_RUNS_DIR="$RUNS_DIR" "$WRITE_RECEIPT" 2>&1)

# Receipt file must exist
RECEIPT_FILE="$RUNS_DIR/smoke-2026-06-04T00:00:00Z.md"
[ -f "$RECEIPT_FILE" ] \
  || fail "RECEIPT: receipt file not created at $RECEIPT_FILE"

# Helper: extract lines belonging to a section (from "## <section>" up to next "## " or EOF)
# Usage: section_of <file> <header-regex>
section_of() {
  local file="$1" hdr="$2"
  awk "/^## /{in_sec=0} $hdr{in_sec=1} in_sec{print}" "$file"
}

# Section headers (match by prefix — receipt may append descriptive suffixes)
grep -qE "^## Written" "$RECEIPT_FILE" \
  || fail "RECEIPT: missing '## Written' section"
grep -qE "^## Superseded" "$RECEIPT_FILE" \
  || fail "RECEIPT: missing '## Superseded' section"
grep -qE "^## Queued" "$RECEIPT_FILE" \
  || fail "RECEIPT: missing '## Queued' section"
grep -qE "^## Skipped" "$RECEIPT_FILE" \
  || fail "RECEIPT: missing '## Skipped' section"

echo "PASS: RECEIPT → receipt file has Written / Superseded / Queued / Skipped sections"

# Written section: new(written) + supersede(written) present; contradict(written) must NOT be there
WRITTEN_SEC=$(section_of "$RECEIPT_FILE" '/^## Written/')
echo "$WRITTEN_SEC" | grep -qiF "AWS Solutions Architect" \
  || fail "RECEIPT: Written section missing new(written) fact"
echo "$WRITTEN_SEC" | grep -qiF "Munich" \
  || fail "RECEIPT: Written section missing supersede(written) fact"
# Wikilink check: Written section must contain a [[wikilink]] referencing me/wiki/
echo "$WRITTEN_SEC" | grep -qE '\[\[me/wiki/' \
  || fail "RECEIPT: Written section missing [[wikilink]] (got: $WRITTEN_SEC)"

echo "PASS: RECEIPT → Written section has new(written) and supersede(written) facts with [[wikilink]]s"

# Superseded section: contradict(written) old_content present; must NOT appear in Written
SUPERSEDED_SEC=$(section_of "$RECEIPT_FILE" '/^## Superseded/')
# DEC3 contradict: old_content="current internship at Aximon"
echo "$SUPERSEDED_SEC" | grep -qiF "current internship at Aximon" \
  || fail "RECEIPT: Superseded section missing contradict(written) old_content fact"
if echo "$WRITTEN_SEC" | grep -qiF "current internship at Aximon"; then
  fail "RECEIPT: contradict(written) must NOT appear in Written section"
fi

echo "PASS: RECEIPT → Superseded section has contradict(written); absent from Written"

# Queued section: queued contradict new content present
QUEUED_SEC=$(section_of "$RECEIPT_FILE" '/^## Queued/')
# DEC3 contradict: content="internship at Aximon ended"
echo "$QUEUED_SEC" | grep -qiF "internship at Aximon ended" \
  || fail "RECEIPT: Queued section missing queued contradict-new fact"

echo "PASS: RECEIPT → Queued section has queued contradict fact"

# Skipped section: duplicate fact present
SKIPPED_SEC=$(section_of "$RECEIPT_FILE" '/^## Skipped/')
echo "$SKIPPED_SEC" | grep -qiF "Python 3.12" \
  || fail "RECEIPT: Skipped section missing duplicate fact"

echo "PASS: RECEIPT → Skipped section has duplicate fact"

# Index file must exist and contain one summary line for this run
INDEX_FILE="$RUNS_DIR/index.md"
[ -f "$INDEX_FILE" ] \
  || fail "RECEIPT: index.md not created at $INDEX_FILE"
grep -q "2026-06-04" "$INDEX_FILE" \
  || fail "RECEIPT: index.md missing entry for 2026-06-04"

echo "PASS: RECEIPT → index.md has entry for the run date"

# =============================================================================
echo ""
echo "All integration smoke tests passed."
