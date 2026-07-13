#!/usr/bin/env bash
# Unit tests for write-receipt.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="$SCRIPT_DIR/../scripts/write-receipt.sh"

[ -x "$WRITER" ] || { echo "FAIL: write-receipt.sh missing or not executable"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

# ── fixture run summary JSON ─────────────────────────────────────────────────
RUNS_DIR=$(mktemp -d "/tmp/dream-runs-test-XXXXXX")
trap 'rm -rf "$RUNS_DIR"' EXIT

# Minimal run summary: the JSON contract write-receipt.sh accepts on stdin.
# This fixture tests DISTINCT action-enum→section bucketing (overview §8.8).
# action values are the reconciliation action enum (new|duplicate|supersede|contradict),
# NOT mode values (append/replace/stale/none).
#
# Fixture cases (non-tautological — each maps to a DISTINCT receipt section):
#   new        (review_status=written)  → Written section ONLY
#   supersede  (review_status=written)  → Written section ONLY (NOT Superseded)
#   contradict (review_status=written)  → Superseded section ONLY (old-line strike; NOT Written)
#   contradict new-fact (review_status=queued) → Queued section ONLY
#   duplicate  (review_status=skipped)  → Skipped section ONLY
#
# Overview §8.8 (normative):
#   Written    = review_status=="written" and (action=="new" or action=="supersede")
#   Superseded = review_status=="written" and action=="contradict"
#   Queued     = review_status=="queued"
#   Skipped    = action=="duplicate" (or review_status=="skipped")
#
# `target` is the flattened "<vault>/<page>" string (write-receipt strips trailing .md for wikilink).
# NOTE: no top-level "date" key — the real Step 8 producer (SKILL.md) does NOT emit one.
# write-receipt.sh must derive the receipt date from window_end (falling back to today),
# never write to "null.md". A prior fixture injected "date" here and masked that bug (C1).
SUMMARY=$(cat <<'EOF'
{
  "run_id":       "dream-2026-06-03T142300Z",
  "window_start": "2026-05-27",
  "window_end":   "2026-06-03",
  "chats_scanned": 4,
  "facts": [
    {
      "content":       "Northwind Clinic internship confirmed for Jun–Aug 2026",
      "target":        "me/wiki/experience.md",
      "action":        "new",
      "review_status": "written",
      "confidence":    "high"
    },
    {
      "content":       "lives in Berlin (moved 2026-06)",
      "old_content":   "lives in Munich",
      "target":        "me/wiki/Bio.md",
      "action":        "supersede",
      "review_status": "written",
      "confidence":    "high"
    },
    {
      "content":       "current internship at Aximon",
      "target":        "me/wiki/Bio.md",
      "action":        "contradict",
      "review_status": "written",
      "confidence":    "high"
    },
    {
      "content":       "left Aximon after internship",
      "target":        "me/wiki/Projects.md",
      "action":        "contradict",
      "review_status": "queued",
      "queue_bucket":  "destructive",
      "confidence":    "medium"
    },
    {
      "content":       "",
      "candidate_content": "Python 3.12",
      "target":        "me/wiki/Skills.md",
      "action":        "duplicate",
      "review_status": "skipped",
      "confidence":    "high"
    },
    {
      "content":       "",
      "target":        "me/wiki/Legacy.md",
      "action":        "duplicate",
      "review_status": "skipped",
      "confidence":    "high"
    }
  ]
}
EOF
)

# ── test 1: receipt file is created with correct sections ────────────────────
printf '%s' "$SUMMARY" | \
  DREAM_RUNS_DIR="$RUNS_DIR" "$WRITER" >/dev/null

RECEIPT="$RUNS_DIR/dream-2026-06-03T142300Z.md"
[ -f "$RECEIPT" ] || fail "receipt file not created at $RECEIPT"
grep -q "^# Dream run — 2026-06-03" "$RECEIPT"      || fail "receipt missing H1 header"
grep -q "^## Written"               "$RECEIPT"      || fail "receipt missing Written section"
grep -q "^## Superseded"            "$RECEIPT"      || fail "receipt missing Superseded section"
grep -q "^## Skipped"               "$RECEIPT"      || fail "receipt missing Skipped section"
grep -q "^## Queued for review"     "$RECEIPT"      || fail "receipt missing Queued section"
echo "PASS: receipt file created with all sections"

# ── test 2: wikilinks + undo id present ──────────────────────────────────────
# target "me/wiki/Bio.md" → [[me/wiki/Bio]] after .md strip
grep -q "\[\[me/wiki/Bio\]\]"               "$RECEIPT" || fail "receipt missing [[me/wiki/Bio]] wikilink (target flattened from me/wiki/Bio.md)"
grep -q "dream-2026-06-03T142300Z"          "$RECEIPT" || fail "receipt missing undo run_id"
grep -Fq 'apply-undo.sh --home "' "$RECEIPT" || fail "receipt missing concrete rollback command"
grep -Fq -- '--run-id "dream-2026-06-03T142300Z"' "$RECEIPT" \
  || fail "receipt rollback command does not select its run_id"
grep -q "lives in Berlin"                   "$RECEIPT" || fail "receipt missing supersede new content"
grep -q "lives in Munich"                   "$RECEIPT" || fail "receipt missing supersede old_content"
# target "me/wiki/experience.md" → [[me/wiki/experience]]
grep -q "\[\[me/wiki/experience\]\]"        "$RECEIPT" || fail "receipt missing [[me/wiki/experience]] wikilink"
echo "PASS: wikilinks (from flattened target string) and undo id present"

# ── test 3: Superseded section contains contradict fact (action=contradict, review_status=written) ──
# Per overview §8.8: Superseded = review_status=="written" AND action=="contradict"
grep -A5 "^## Superseded" "$RECEIPT" | grep -q "current internship at Aximon" \
  || fail "Superseded section missing contradict fact (action=contradict, review_status=written)"
# contradict(written) must NOT appear in Written section
grep -A5 "^## Written" "$RECEIPT" | grep -q "current internship at Aximon" \
  && fail "Contradict (written) fact incorrectly appears in Written section — must be in Superseded only"
echo "PASS: Superseded section has contradict(written); absent from Written"

# ── test 3b: Written section contains supersede (action=supersede, review_status=written) — DISTINCT ─
# Per overview §8.8: Written = review_status=="written" AND (action=="new" OR action=="supersede")
grep -A5 "^## Written" "$RECEIPT" | grep -q "lives in Berlin" \
  || fail "Written section missing supersede fact (action=supersede, review_status=written)"
# supersede(written) must NOT appear in Superseded section (only contradict goes there)
grep -A5 "^## Superseded" "$RECEIPT" | grep -q "lives in Berlin" \
  && fail "Supersede (written) fact incorrectly appears in Superseded section — must be in Written only"
# new(written) also in Written
grep -A5 "^## Written" "$RECEIPT" | grep -q "Northwind Clinic" \
  || fail "Written section missing new fact (action=new, review_status=written)"
echo "PASS: supersede(written) in Written; contradict(written) in Superseded — DISTINCT sections confirmed"

# ── test 4: skipped section contains duplicate fact (action=duplicate) ───────
grep -A5 "^## Skipped" "$RECEIPT" | grep -q "Python 3.12" \
  || fail "Skipped section missing duplicate fact (action=duplicate)"
grep -q '^## Skipped as duplicates$' "$RECEIPT" \
  || fail "Skipped section has misleading heading"
grep -A5 "^## Skipped" "$RECEIPT" | grep -q -- '- ""' \
  && fail "Skipped section rendered an empty duplicate fact"
grep -A5 "^## Skipped" "$RECEIPT" | grep -Fq -- 'Duplicate already present in [[me/wiki/Legacy]]' \
  || fail "Skipped section missing target-only fallback for a legacy duplicate"
echo "PASS: Skipped section populated with duplicate"

# ── test 5: queued section contains queued contradict new-fact with bucket ────
grep -A5 "^## Queued for review" "$RECEIPT" | grep -q "left Aximon" \
  || fail "Queued section missing queued contradict new-fact"
grep -A5 "^## Queued for review" "$RECEIPT" | grep -q "destructive" \
  || fail "Queued section missing queue_bucket label"
echo "PASS: Queued section populated with queued contradict new-fact + bucket"

# ── test 6: index.md receives exactly one summary line ───────────────────────
# Written count = action in (new,supersede) with review_status=written
# In this fixture: 1 new(written) + 1 supersede(written) → N_WRITTEN_CLEAN=2
INDEX="$RUNS_DIR/index.md"
[ -f "$INDEX" ] || fail "reports_dir/index.md not created"
LINE_COUNT=$(grep -c '<!-- dream-run:dream-2026-06-03T142300Z -->' "$INDEX" || true)
[ "$LINE_COUNT" -eq 1 ] || fail "index.md: expected 1 line for run_id, got $LINE_COUNT"
grep -q "2026-06-03" "$INDEX" || fail "index.md missing date entry"
grep -q '\[\['"$(basename "$RUNS_DIR")"'/dream-2026-06-03T142300Z\]\]' "$INDEX" \
  || fail "index.md missing run-scoped receipt link"
grep -q "1 queued"  "$INDEX" || fail "index.md missing queued count"
echo "PASS: index.md one-line entry"

# ── test 7: idempotent index append — second run does not duplicate the line ──
printf '%s' "$SUMMARY" | \
  DREAM_RUNS_DIR="$RUNS_DIR" "$WRITER" >/dev/null

DUPE_COUNT=$(grep -c '<!-- dream-run:dream-2026-06-03T142300Z -->' "$INDEX" || true)
[ "$DUPE_COUNT" -eq 1 ] || fail "index.md: idempotent re-run added duplicate line (count=$DUPE_COUNT)"
echo "PASS: index.md idempotent (no duplicate on re-run)"

# ── test 7b: two runs ending on the same date get separate receipts/index rows ─
SAME_DATE_SUMMARY=$(printf '%s' "$SUMMARY" | jq \
  '.run_id = "dream-2026-06-03T180000Z" | .chats_scanned = 7')
printf '%s' "$SAME_DATE_SUMMARY" | DREAM_RUNS_DIR="$RUNS_DIR" "$WRITER" >/dev/null
[ -f "$RUNS_DIR/dream-2026-06-03T180000Z.md" ] \
  || fail "same-date second run did not receive its own receipt"
[ "$(grep -c '<!-- dream-run:dream-2026-06-03T' "$INDEX" || true)" -eq 2 ] \
  || fail "same-date runs collided in index.md"
echo "PASS: same-date runs remain isolated by run_id"

# ── test 7c: rerun refreshes the existing run row instead of appending ─────
UPDATED_SUMMARY=$(printf '%s' "$SAME_DATE_SUMMARY" | jq '.chats_scanned = 9')
printf '%s' "$UPDATED_SUMMARY" | DREAM_RUNS_DIR="$RUNS_DIR" "$WRITER" >/dev/null
[ "$(grep -c '<!-- dream-run:dream-2026-06-03T180000Z -->' "$INDEX" || true)" -eq 1 ] \
  || fail "rerun duplicated its run_id index row"
grep '<!-- dream-run:dream-2026-06-03T180000Z -->' "$INDEX" | grep -q '9 chats' \
  || fail "rerun did not refresh its run_id index row"
echo "PASS: rerun idempotently refreshes its run_id index row"

# ── test 8 (M5): dry-run emits receipt to STDOUT and writes NO index/receipt file ─
DRYRUN_DIR=$(mktemp -d "/tmp/dream-runs-dry-XXXXXX")
DRY_SUMMARY=$(printf '%s' "$SUMMARY" | jq '.run_id = "dream-2026-06-03T150000Z" | .date = "2026-06-03"')
DRY_OUT=$(printf '%s' "$DRY_SUMMARY" | DREAM_RUNS_DIR="$DRYRUN_DIR" "$WRITER" --dry-run)
printf '%s' "$DRY_OUT" | grep -q "^# Dream run — 2026-06-03" || fail "--dry-run: receipt body not emitted to stdout"
[ ! -f "$DRYRUN_DIR/index.md" ]      || fail "--dry-run: index.md was created (index update must be suppressed)"
[ ! -f "$DRYRUN_DIR/dream-2026-06-03T150000Z.md" ] || fail "--dry-run: receipt file written to disk (dry-run must be stdout-only)"
rm -rf "$DRYRUN_DIR"
echo "PASS: --dry-run emits receipt to stdout; no index.md / receipt file on disk"

# ── test 9 (C1): dateless producer → receipt filed under window_end, never null.md ──
C1_DIR=$(mktemp -d "/tmp/dream-runs-c1-XXXXXX")
printf '%s' "$SUMMARY" | DREAM_RUNS_DIR="$C1_DIR" "$WRITER" >/dev/null
[ -f "$C1_DIR/dream-2026-06-03T142300Z.md" ] || fail "C1: dateless summary did not produce run-scoped receipt"
[ ! -f "$C1_DIR/null.md" ]     || fail "C1: receipt misfiled to null.md (date collapsed to null)"
grep -q "^# Dream run — 2026-06-03" "$C1_DIR/dream-2026-06-03T142300Z.md" || fail "C1: header date is not window_end"
grep -q "\[\[$(basename "$C1_DIR")/dream-2026-06-03T142300Z\]\]" "$C1_DIR/index.md" || fail "C1: index wikilink is not run-scoped"
grep -q "null" "$C1_DIR/index.md" && fail "C1: index line contains literal 'null'"
rm -rf "$C1_DIR"
echo "PASS: dateless producer → window_end-dated receipt, no null.md (C1 regression guard)"

# ── test 10 (C1): explicit .date wins over window_end (precedence preserved) ──────
PREC_DIR=$(mktemp -d "/tmp/dream-runs-prec-XXXXXX")
printf '%s' "$SUMMARY" | jq '.date = "2026-06-10"' | DREAM_RUNS_DIR="$PREC_DIR" "$WRITER" >/dev/null
[ -f "$PREC_DIR/dream-2026-06-03T142300Z.md" ] || fail "C1: receipt filename is not run-scoped"
grep -q '^# Dream run — 2026-06-10' "$PREC_DIR/dream-2026-06-03T142300Z.md" \
  || fail "C1: explicit .date did not take precedence in receipt content"
rm -rf "$PREC_DIR"
echo "PASS: explicit .date takes precedence over window_end"

# ── test 11: empty facts array → exit 0, all sections present, valid index entry ─
EMPTY_FACTS_DIR=$(mktemp -d "/tmp/dream-runs-emptyfacts-XXXXXX")
EMPTY_FACTS_SUMMARY=$(cat <<'EOF'
{
  "run_id":       "dream-2026-06-03T160000Z",
  "window_start": "2026-05-27",
  "window_end":   "2026-06-03",
  "chats_scanned": 2,
  "facts": []
}
EOF
)
printf '%s' "$EMPTY_FACTS_SUMMARY" | DREAM_RUNS_DIR="$EMPTY_FACTS_DIR" "$WRITER" >/dev/null
[ -f "$EMPTY_FACTS_DIR/dream-2026-06-03T160000Z.md" ] || fail "empty facts: receipt file not created"
grep -q "^## Written"           "$EMPTY_FACTS_DIR/dream-2026-06-03T160000Z.md" || fail "empty facts: Written section missing"
grep -q "^## Queued for review" "$EMPTY_FACTS_DIR/dream-2026-06-03T160000Z.md" || fail "empty facts: Queued section missing"
grep -q "^## Skipped"           "$EMPTY_FACTS_DIR/dream-2026-06-03T160000Z.md" || fail "empty facts: Skipped section missing"
grep -q "^## Superseded"        "$EMPTY_FACTS_DIR/dream-2026-06-03T160000Z.md" || fail "empty facts: Superseded section missing"
[ -f "$EMPTY_FACTS_DIR/index.md" ] || fail "empty facts: index.md not created"
grep -q "2026-06-03" "$EMPTY_FACTS_DIR/index.md" || fail "empty facts: index entry missing date"
rm -rf "$EMPTY_FACTS_DIR"
echo "PASS: empty facts array → receipt with all sections + valid index entry (exit 0)"

# ── test 12: null facts field → exit 0, receipt renders without error ─────────
NULL_FACTS_DIR=$(mktemp -d "/tmp/dream-runs-nullfacts-XXXXXX")
NULL_FACTS_SUMMARY=$(cat <<'EOF'
{
  "run_id":       "dream-2026-06-03T170000Z",
  "window_start": "2026-05-27",
  "window_end":   "2026-06-03",
  "chats_scanned": 0,
  "facts": null
}
EOF
)
printf '%s' "$NULL_FACTS_SUMMARY" | DREAM_RUNS_DIR="$NULL_FACTS_DIR" "$WRITER" >/dev/null
[ -f "$NULL_FACTS_DIR/dream-2026-06-03T170000Z.md" ] || fail "null facts: receipt not created"
grep -q "^## Written"    "$NULL_FACTS_DIR/dream-2026-06-03T170000Z.md" || fail "null facts: Written section missing"
grep -q "^## Superseded" "$NULL_FACTS_DIR/dream-2026-06-03T170000Z.md" || fail "null facts: Superseded section missing"
rm -rf "$NULL_FACTS_DIR"
echo "PASS: null facts field → receipt rendered without error (exit 0)"

# ── test 13: concrete undo metadata must match the receipt's run_id ─────────
BAD_UNDO_DIR=$(mktemp -d "/tmp/dream-runs-badundo-XXXXXX")
BAD_UNDO_SUMMARY=$(printf '%s' "$SUMMARY" | jq \
  '.undo_home = "/tmp/dream-home" | .undo_log = "/tmp/dream-home/undo/a-different-run.jsonl"')
if printf '%s' "$BAD_UNDO_SUMMARY" | DREAM_RUNS_DIR="$BAD_UNDO_DIR" "$WRITER" >/dev/null 2>&1; then
  fail "mismatched undo_log/run_id unexpectedly produced a receipt"
fi
[ ! -e "$BAD_UNDO_DIR/dream-2026-06-03T142300Z.md" ] \
  || fail "mismatched undo metadata left a misleading receipt"
rm -rf "$BAD_UNDO_DIR"
echo "PASS: receipt refuses mismatched undo_log/run_id metadata"

# ── test 14: receipt-path failure is fail-closed and cannot update the index ─
FAILED_RECEIPT_DIR=$(mktemp -d "/tmp/dream-runs-failedreceipt-XXXXXX")
mkdir "$FAILED_RECEIPT_DIR/dream-2026-06-03T142300Z.md"
if printf '%s' "$SUMMARY" | DREAM_RUNS_DIR="$FAILED_RECEIPT_DIR" "$WRITER" \
  > "$FAILED_RECEIPT_DIR/stdout" 2> "$FAILED_RECEIPT_DIR/stderr"; then
  fail "receipt path failure returned success"
fi
[ ! -e "$FAILED_RECEIPT_DIR/index.md" ] \
  || fail "receipt path failure still wrote the run index"
rg -Fq 'receipt path is not a regular file' "$FAILED_RECEIPT_DIR/stderr" \
  || fail "receipt path failure did not explain the persistence error"
rm -rf "$FAILED_RECEIPT_DIR"
echo "PASS: receipt persistence failure is nonzero and leaves no index entry"

# ── test 15: the advertised command executes for the full accepted ID alphabet ─
ROLLBACK_HOME=$(mktemp -d "/tmp/dream-receipt-rollback-XXXXXX")
ROLLBACK_VAULT="$ROLLBACK_HOME/vault"
ROLLBACK_RUN='dream.test_1-2'
mkdir -p "$ROLLBACK_VAULT/wiki" "$ROLLBACK_HOME/undo" "$ROLLBACK_HOME/reports"
printf '# Page\n\n## Facts\n' > "$ROLLBACK_VAULT/wiki/page.md"
"$SCRIPT_DIR/../scripts/vault-writer.sh" \
  --vault "$ROLLBACK_VAULT" --page wiki/page.md --section Facts \
  --content 'rollback command fact' --mode append \
  --undo-log "$ROLLBACK_HOME/undo/$ROLLBACK_RUN.jsonl" \
  --run-id "$ROLLBACK_RUN" --candidate-id candidate-receipt-test \
  --no-index-update
ROLLBACK_SUMMARY=$(jq -cn \
  --arg run_id "$ROLLBACK_RUN" \
  --arg home "$ROLLBACK_HOME" \
  --arg log "$ROLLBACK_HOME/undo/$ROLLBACK_RUN.jsonl" \
  '{run_id:$run_id,date:"2026-06-03",window_start:"2026-06-02",window_end:"2026-06-03",chats_scanned:1,undo_home:$home,undo_log:$log,facts:[{target:"test/wiki/page.md",content:"rollback command fact",action:"new",review_status:"written"}]}')
printf '%s' "$ROLLBACK_SUMMARY" | DREAM_RUNS_DIR="$ROLLBACK_HOME/reports" "$WRITER" >/dev/null
ROLLBACK_RECEIPT="$ROLLBACK_HOME/reports/$ROLLBACK_RUN.md"
ROLLBACK_COMMAND=$(sed -n 's/^Rollback: `\(.*\)`$/\1/p' "$ROLLBACK_RECEIPT")
[ -n "$ROLLBACK_COMMAND" ] || fail "receipt did not render an executable rollback command"
bash -c "$ROLLBACK_COMMAND" >/dev/null
! grep -Fq -- '- rollback command fact' "$ROLLBACK_VAULT/wiki/page.md" \
  || fail "receipt-advertised rollback command did not revert the mutation"
[ ! -e "$ROLLBACK_HOME/undo/$ROLLBACK_RUN.jsonl" ] \
  || fail "receipt-advertised rollback command did not consume the completed log"
rm -rf "$ROLLBACK_HOME"
echo "PASS: advertised rollback executes for dot/underscore/hyphen run IDs"

echo "All write-receipt.sh tests passed."
