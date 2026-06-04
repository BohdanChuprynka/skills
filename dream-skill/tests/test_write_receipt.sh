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
  "run_id":       "dream-2026-06-03T14:23:00Z",
  "window_start": "2026-05-27",
  "window_end":   "2026-06-03",
  "chats_scanned": 4,
  "facts": [
    {
      "content":       "Cleveland Clinic internship confirmed for Jun–Aug 2026",
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
      "content":       "Python 3.12",
      "target":        "me/wiki/Skills.md",
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

RECEIPT="$RUNS_DIR/2026-06-03.md"
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
grep -q "dream-2026-06-03T14:23:00Z"        "$RECEIPT" || fail "receipt missing undo run_id"
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
grep -A5 "^## Written" "$RECEIPT" | grep -q "Cleveland Clinic" \
  || fail "Written section missing new fact (action=new, review_status=written)"
echo "PASS: supersede(written) in Written; contradict(written) in Superseded — DISTINCT sections confirmed"

# ── test 4: skipped section contains duplicate fact (action=duplicate) ───────
grep -A5 "^## Skipped" "$RECEIPT" | grep -q "Python 3.12" \
  || fail "Skipped section missing duplicate fact (action=duplicate)"
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
LINE_COUNT=$(grep -c "2026-06-03" "$INDEX" || true)
[ "$LINE_COUNT" -eq 1 ] || fail "index.md: expected 1 line for date, got $LINE_COUNT"
grep -q "2026-06-03" "$INDEX" || fail "index.md missing date entry"
grep -q "1 queued"  "$INDEX" || fail "index.md missing queued count"
echo "PASS: index.md one-line entry"

# ── test 7: idempotent index append — second run does not duplicate the line ──
printf '%s' "$SUMMARY" | \
  DREAM_RUNS_DIR="$RUNS_DIR" "$WRITER" >/dev/null

DUPE_COUNT=$(grep -c "2026-06-03" "$INDEX" || true)
[ "$DUPE_COUNT" -eq 1 ] || fail "index.md: idempotent re-run added duplicate line (count=$DUPE_COUNT)"
echo "PASS: index.md idempotent (no duplicate on re-run)"

# ── test 8 (M5): dry-run emits receipt to STDOUT and writes NO index/receipt file ─
DRYRUN_DIR=$(mktemp -d "/tmp/dream-runs-dry-XXXXXX")
DRY_SUMMARY=$(printf '%s' "$SUMMARY" | jq '.run_id = "dream-2026-06-03T15:00:00Z" | .date = "2026-06-03"')
DRY_OUT=$(printf '%s' "$DRY_SUMMARY" | DREAM_RUNS_DIR="$DRYRUN_DIR" "$WRITER" --dry-run)
printf '%s' "$DRY_OUT" | grep -q "^# Dream run — 2026-06-03" || fail "--dry-run: receipt body not emitted to stdout"
[ ! -f "$DRYRUN_DIR/index.md" ]      || fail "--dry-run: index.md was created (index update must be suppressed)"
[ ! -f "$DRYRUN_DIR/2026-06-03.md" ] || fail "--dry-run: receipt file written to disk (dry-run must be stdout-only)"
rm -rf "$DRYRUN_DIR"
echo "PASS: --dry-run emits receipt to stdout; no index.md / receipt file on disk"

# ── test 9 (C1): dateless producer → receipt filed under window_end, never null.md ──
C1_DIR=$(mktemp -d "/tmp/dream-runs-c1-XXXXXX")
printf '%s' "$SUMMARY" | DREAM_RUNS_DIR="$C1_DIR" "$WRITER" >/dev/null
[ -f "$C1_DIR/2026-06-03.md" ] || fail "C1: dateless summary did not produce window_end-dated receipt (2026-06-03.md)"
[ ! -f "$C1_DIR/null.md" ]     || fail "C1: receipt misfiled to null.md (date collapsed to null)"
grep -q "^# Dream run — 2026-06-03" "$C1_DIR/2026-06-03.md" || fail "C1: header date is not window_end"
grep -q "\[\[$(basename "$C1_DIR")/2026-06-03\]\]" "$C1_DIR/index.md" || fail "C1: index wikilink not dated from window_end"
grep -q "null" "$C1_DIR/index.md" && fail "C1: index line contains literal 'null'"
rm -rf "$C1_DIR"
echo "PASS: dateless producer → window_end-dated receipt, no null.md (C1 regression guard)"

# ── test 10 (C1): explicit .date wins over window_end (precedence preserved) ──────
PREC_DIR=$(mktemp -d "/tmp/dream-runs-prec-XXXXXX")
printf '%s' "$SUMMARY" | jq '.date = "2026-06-10"' | DREAM_RUNS_DIR="$PREC_DIR" "$WRITER" >/dev/null
[ -f "$PREC_DIR/2026-06-10.md" ] || fail "C1: explicit .date did not take precedence over window_end"
rm -rf "$PREC_DIR"
echo "PASS: explicit .date takes precedence over window_end"

echo "All write-receipt.sh tests passed."
