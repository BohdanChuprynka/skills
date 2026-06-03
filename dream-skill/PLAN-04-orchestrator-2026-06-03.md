# Plan 4 — Orchestrator + Receipt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the on-demand `/dream-skill` pipeline end-to-end: `find-chats.sh` enumerates the correct transcript window, MAP dispatches one subagent per chat via the Task/Agent tool, REDUCE merges candidates across chats, then hand-off to Plan 2 (ROUTE) and Plan 3 (RECONCILE) pipelines, followed by terminal REVIEW via the existing `queue.sh`, APPLY via `vault-writer.sh`, RECEIPT via `write-receipt.sh`, and MARKER advance. Also removes the legacy SessionEnd hook wiring per REDESIGN §5.

**Architecture:** Three new deterministic shell scripts (`find-chats.sh`, `write-receipt.sh`, marker update) plus prose orchestration written into `SKILL.md`. The MAP/REDUCE stages are LLM judgment — specified as a dispatch prompt + golden fixtures, never run in CI. All deterministic pieces carry plain-shell unit tests (`fail()` + `PASS:` echoes, `mktemp`/env-var roots) mirroring the existing `tests/test_vault_writer.sh` style.

**Tech Stack:** Bash (POSIX-ish, `set -euo pipefail`), `find`/`stat` for mtime enumeration, `jq` (optional, fail-open), `date` for window arithmetic, `awk` for receipt rendering, plain-shell tests (no bats).

**Repo root:** `/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill`

---

## File Structure

- **New:** `scripts/find-chats.sh` — marker + window resolution + transcript enumeration + skip-list + batch boundaries.
- **New:** `scripts/write-receipt.sh` — render `<reports_dir>/<date>.md` + idempotent one-line append to `<reports_dir>/index.md`. `reports_dir` comes from `config.toml` (not hardcoded `dream-runs/`).
- **Modify:** `dream-skill/skills/dream-skill/SKILL.md` (EXISTS — strip the auto-mode/SessionEnd sections; add on-demand orchestration steps referencing `## Routing` and `## Reconciliation` as "defined below"). Plans 2 and 3 append those sections respectively. Build order: Plan 4 first.
- **Modify:** `hooks/hooks.json` — remove the `SessionEnd` entry; keep `SessionStart` / `check-pending.sh` untouched (it will be retired separately when Plan 4 is fully live).
- **New:** `tests/test_find_chats.sh` — unit tests for window resolution, mtime filtering, ignore skip, batch boundaries, marker handling.
- **New:** `tests/test_write_receipt.sh` — unit tests for receipt rendering and idempotent index append.
- **New:** `tests/fixtures/map/` — golden fixtures for MAP dispatch: sample `.jsonl` transcript snippets → expected candidate-fact JSON arrays (not run in CI; document the manual eval step).

---

## Cross-plan contracts honored

All three JSON contracts from `PLAN-OVERVIEW-2026-06-03.md` are used as-is. Quoted for implementer reference:

**Candidate fact** (produced by MAP, consumed by REDUCE/ROUTE/RECONCILE) — from overview §4:
```json
{
  "content":           "Cleveland Clinic internship confirmed for Jun–Aug 2026",
  "confidence":        "high | medium | low",
  "source_chat":       "<session-id>",
  "source_date":       "2026-06-01",
  "type":              "world-fact | belief | observation | experience",
  "evidence":          "short quote/paraphrase from the chat",
  "suggested_section": "Experience"
}
```
Required fields: `content`, `confidence`, `source_chat`, `source_date`. Optional: `type`, `evidence`, `suggested_section`. `needs_review` is NOT on the candidate — it is set by reconciliation. `suggested_section` is a hint only; the router may override.

**Routing decision** (Plan 2 output, per candidate) — from overview §4:
```json
{ "status": "routed | ambiguous | gap",
  "vault": "me", "page": "wiki/Bio.md", "section": "Location",
  "routing_confidence": "high | medium | low" }
```
- Field is `status` (not `routing_status`). `page` is relative to the vault root; the orchestrator resolves the absolute path from `config[vault].root` + `page` (Step 5b). `ambiguous`/`gap` → route to `uncertain` queue bucket + routing-gaps log; never silently guessed.

**Reconciliation decision** (Plan 3 output, per routed candidate) — from overview §4:
```json
{
  "action":              "new | duplicate | supersede | contradict",
  "mode":                "append | replace | stale | none",
  "target":              { "vault": "me", "page": "wiki/experience.md", "section": "Experience" },
  "old_content":         "lives in Berlin",
  "content":             "lives in Munich (moved 2026-06)",
  "candidate_confidence":"high | medium | low",
  "needs_review":        true,
  "rationale":           "newer source_date, same subject → supersede"
}
```
`action` enum is EXACTLY `new|duplicate|supersede|contradict`. `mode` is `append|replace|stale|none` (`none` for duplicate). Field is `rationale` (not `reason`). `apply-decision.sh` (Plan 3) owns the action→mode→vault-writer mapping.

**Invariants this plan enforces:**
1. `mode` values in reconciliation decisions are exactly `append|replace|stale|none` (`none` = duplicate, no vault write). Values passed to `vault-writer.sh` are `append|replace|stale` only.
2. Every `needs_review:true` item is appended to `queue.sh`, not silently written.
3. MAP runs inside a subagent at invocation time; it never executes inside a hook.
4. The last-run marker advances only after a batch completes; a failed batch leaves the marker unchanged.
5. Window default = last 7 days; `--all` = explicit weekly-batched backfill.

---

## Task 1: `find-chats.sh` — transcript enumeration

**Files:**
- New: `scripts/find-chats.sh`
- New: `tests/test_find_chats.sh`

### Step sequence

- [ ] **Step 1.1: Write the failing tests** — create `tests/test_find_chats.sh` with the setup harness and the first two tests (window default + mtime filter):

```bash
#!/usr/bin/env bash
# Unit tests for find-chats.sh
# Uses DREAM_PROJECTS_ROOT to redirect away from real ~/.claude/projects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FINDER="$SCRIPT_DIR/../scripts/find-chats.sh"

[ -x "$FINDER" ] || { echo "FAIL: find-chats.sh missing or not executable"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

# ── fixture root ────────────────────────────────────────────────────────────
PROJ_ROOT=$(mktemp -d "/tmp/dream-projects-test-XXXXXX")
MARKER_DIR=$(mktemp -d "/tmp/dream-marker-test-XXXXXX")
trap 'rm -rf "$PROJ_ROOT" "$MARKER_DIR"' EXIT

# Helper: create a .jsonl file with an explicit mtime (days ago)
make_chat() {
  local path="$1" days_ago="$2"
  mkdir -p "$(dirname "$path")"
  echo '{"role":"user","content":"hello"}' > "$path"
  # macOS: touch -t [[CC]YY]MMDDhhmm[.ss]
  local ts
  ts=$(date -v "-${days_ago}d" +%Y%m%d%H%M 2>/dev/null \
    || date --date="${days_ago} days ago" +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

# ── test 1: default window (last 7 days) finds recent chats, skips old ───────
make_chat "$PROJ_ROOT/proj-a/aaa.jsonl" 3   # 3 days ago → inside window
make_chat "$PROJ_ROOT/proj-a/bbb.jsonl" 10  # 10 days ago → outside window

OUT=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
      DREAM_MARKER_DIR="$MARKER_DIR" \
      "$FINDER" 2>/dev/null)

echo "$OUT" | grep -q "aaa.jsonl" || fail "recent chat not included in default 7d window"
echo "$OUT" | grep -q "bbb.jsonl" && fail "old chat included in default 7d window (should be excluded)"
echo "PASS: default 7-day window"

# ── test 2: --since flag narrows/widens the window ───────────────────────────
SINCE=$(date -v "-5d" +%Y-%m-%d 2>/dev/null || date --date="5 days ago" +%Y-%m-%d)
OUT2=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" --since "$SINCE" 2>/dev/null)

echo "$OUT2" | grep -q "aaa.jsonl" || fail "--since: recent chat missing"
echo "$OUT2" | grep -q "bbb.jsonl" && fail "--since: old chat included when outside --since range"
echo "PASS: --since narrows window"

echo "All find-chats.sh tests passed."
```

- [ ] **Step 1.2: Run to confirm failure**

```bash
bash tests/test_find_chats.sh
```
Expected: `FAIL: find-chats.sh missing or not executable`.

- [ ] **Step 1.3: Create `scripts/find-chats.sh` — scaffold + arg parsing + window resolution**

```bash
#!/usr/bin/env bash
# find-chats.sh — enumerate ~/.claude/projects/**/*.jsonl files whose mtime
# falls inside the requested time window, skip --ignore'd chats, emit weekly
# batch boundaries for large windows.
#
# Usage:
#   find-chats.sh [--since <YYYY-MM-DD>] [--all]
#
# Environment overrides (for tests):
#   DREAM_PROJECTS_ROOT  — replaces ~/.claude/projects
#   DREAM_MARKER_DIR     — dir holding the `last-run` marker file
#   DREAM_SKILL_HOME     — plugin root (for scripts/private-state.sh)
#
# Output (stdout):
#   Lines of the form:
#       BATCH:<YYYY-MM-DD>:<YYYY-MM-DD>
#       <absolute-path-to-chat.jsonl>
#       <absolute-path-to-chat.jsonl>
#       BATCH:<YYYY-MM-DD>:<YYYY-MM-DD>   # next week boundary (--all only)
#       ...
#   A single BATCH header precedes all paths when the window is ≤7 days.
#   Multiple BATCH headers are emitted week-by-week for --all or large --since.
#
# Exit codes: 0 = success (even if zero chats found); 1 = fatal error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_ROOT="${DREAM_PROJECTS_ROOT:-$HOME/.claude/projects}"
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
MARKER_FILE="$MARKER_DIR/last-run"
SKILL_HOME="${DREAM_SKILL_HOME:-$(dirname "$SCRIPT_DIR")}"
PRIVATE_STATE="$SKILL_HOME/scripts/private-state.sh"

MODE="default"   # default | since | all
SINCE_DATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --since) MODE="since"; SINCE_DATE="${2:-}"; shift 2 ;;
    --all)   MODE="all";   shift ;;
    *) echo "find-chats.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

die() { echo "find-chats.sh: $*" >&2; exit 1; }

# ── resolve window start as a Unix timestamp ─────────────────────────────────
now_ts=$(date +%s)

case "$MODE" in
  default)
    if [ -f "$MARKER_FILE" ]; then
      # marker exists: start = marker content (YYYY-MM-DD or epoch integer)
      marker_content=$(cat "$MARKER_FILE" 2>/dev/null | tr -d '[:space:]')
      if printf '%s' "$marker_content" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        # clean YYYY-MM-DD
        window_start=$(date -j -f "%Y-%m-%d" "$marker_content" +%s 2>/dev/null \
          || date -d "$marker_content" +%s 2>/dev/null) \
          || window_start=""
      elif printf '%s' "$marker_content" | grep -qE '^[0-9]+$'; then
        # clean epoch integer
        window_start="$marker_content"
      else
        # corrupted marker — NEVER fall back to epoch-0/all-history; use 7-day safe default
        echo "find-chats.sh: WARNING: corrupted marker content '$marker_content'; defaulting to 7-day window" >&2
        window_start=""
      fi
      # If parse failed or empty, fall back to 7 days (never epoch-0)
      if [ -z "${window_start:-}" ] || ! printf '%s' "${window_start:-}" | grep -qE '^[0-9]+$'; then
        window_start=$(( now_ts - 7 * 86400 ))
      fi
    else
      # No marker: default to last 7 days
      window_start=$(( now_ts - 7 * 86400 ))
    fi
    ;;
  since)
    [ -n "$SINCE_DATE" ] || die "--since requires a date argument (YYYY-MM-DD)"
    window_start=$(date -j -f "%Y-%m-%d" "$SINCE_DATE" +%s 2>/dev/null \
      || date -d "$SINCE_DATE" +%s 2>/dev/null) \
      || die "cannot parse --since date: $SINCE_DATE"
    ;;
  all)
    # Earliest possible: the oldest .jsonl mtime. We use epoch 0 as lower bound
    # and let the batch-boundary logic slice it week by week.
    window_start=0
    ;;
esac

# ── emit weekly batch boundaries + collect paths ─────────────────────────────
# For windows wider than 7 days (--all or old --since), slice into 7-day batches
# so the orchestrator can process and advance the marker one batch at a time.

WINDOW_DAYS=$(( (now_ts - window_start) / 86400 ))
BATCH_SIZE=7  # days per batch

emit_batch() {
  local batch_start="$1" batch_end="$2"
  local bs_fmt be_fmt
  bs_fmt=$(date -r "$batch_start" +%Y-%m-%d 2>/dev/null || date -d "@$batch_start" +%Y-%m-%d)
  be_fmt=$(date -r "$batch_end"   +%Y-%m-%d 2>/dev/null || date -d "@$batch_end"   +%Y-%m-%d)
  echo "BATCH:${bs_fmt}:${be_fmt}"
  # enumerate chats whose mtime falls in [batch_start, batch_end)
  while IFS= read -r -d '' f; do
    fmtime=$(stat -f "%m" "$f" 2>/dev/null || stat -c "%Y" "$f" 2>/dev/null || echo 0)
    if [ "$fmtime" -ge "$batch_start" ] && [ "$fmtime" -lt "$batch_end" ]; then
      # skip --ignore'd chats
      if [ -x "$PRIVATE_STATE" ]; then
        state=$("$PRIVATE_STATE" "$f" 2>/dev/null || echo "record")
      else
        state="record"
      fi
      [ "$state" = "ignore" ] && continue
      echo "$f"
    fi
  done < <(find "$PROJECTS_ROOT" -name "*.jsonl" -print0 2>/dev/null | sort -z)
}

if [ "$WINDOW_DAYS" -le "$BATCH_SIZE" ]; then
  # Single batch — emit one BATCH header then all paths
  emit_batch "$window_start" "$now_ts"
else
  # Multi-batch: slice from oldest to newest, one week at a time
  cur="$window_start"
  while [ "$cur" -lt "$now_ts" ]; do
    next=$(( cur + BATCH_SIZE * 86400 ))
    [ "$next" -gt "$now_ts" ] && next="$now_ts"
    emit_batch "$cur" "$next"
    cur="$next"
  done
fi
```

Make it executable:
```bash
chmod +x scripts/find-chats.sh
```

- [ ] **Step 1.4: Run tests to verify steps 1.1–1.3 pass**

```bash
bash tests/test_find_chats.sh
```
Expected: `PASS: default 7-day window` and `PASS: --since narrows window`.

- [ ] **Step 1.5: Add remaining tests** — append before the final `echo "All find-chats.sh tests passed."`:

```bash
# ── test 3: --all emits BATCH headers and includes all chats ─────────────────
make_chat "$PROJ_ROOT/proj-b/old.jsonl" 30  # 30 days ago
OUT3=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" --all 2>/dev/null)

echo "$OUT3" | grep -q "^BATCH:" || fail "--all: no BATCH header emitted"
echo "$OUT3" | grep -q "old.jsonl" || fail "--all: 30-day-old chat not included"
echo "PASS: --all includes old chats + emits BATCH headers"

# ── test 4: --ignore'd chat is skipped ──────────────────────────────────────
IGNORE_CHAT="$PROJ_ROOT/proj-c/private.jsonl"
make_chat "$IGNORE_CHAT" 1
# Write a fake private-state.sh in a temp SKILL_HOME that always returns "ignore"
FAKE_HOME=$(mktemp -d "/tmp/dream-fakehome-XXXXXX")
mkdir -p "$FAKE_HOME/scripts"
printf '#!/usr/bin/env bash\necho "ignore"\n' > "$FAKE_HOME/scripts/private-state.sh"
chmod +x "$FAKE_HOME/scripts/private-state.sh"

OUT4=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       DREAM_SKILL_HOME="$FAKE_HOME" \
       "$FINDER" 2>/dev/null)
rm -rf "$FAKE_HOME"

echo "$OUT4" | grep -q "private.jsonl" && fail "--ignore'd chat was NOT skipped"
echo "PASS: --ignore'd chat is skipped"

# ── test 5: marker-based window — only chats newer than marker are included ──
MARKER_FILE_PATH="$MARKER_DIR/last-run"
# marker = 6 days ago: chat at 3d (inside) and chat at 10d (outside already made)
MARKER_DATE=$(date -v "-6d" +%Y-%m-%d 2>/dev/null || date --date="6 days ago" +%Y-%m-%d)
echo "$MARKER_DATE" > "$MARKER_FILE_PATH"

OUT5=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" 2>/dev/null)

echo "$OUT5" | grep -q "aaa.jsonl" || fail "marker window: recent chat missing"
echo "$OUT5" | grep -q "bbb.jsonl" && fail "marker window: old chat included"
rm -f "$MARKER_FILE_PATH"
echo "PASS: marker-based window"

# ── test 6: large window (>7 days --since) emits multiple BATCH headers ──────
SINCE_OLD=$(date -v "-20d" +%Y-%m-%d 2>/dev/null || date --date="20 days ago" +%Y-%m-%d)
OUT6=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" --since "$SINCE_OLD" 2>/dev/null)

BATCH_COUNT=$(echo "$OUT6" | grep -c "^BATCH:" || true)
[ "$BATCH_COUNT" -ge 2 ] || fail "large --since window: expected ≥2 BATCH headers, got $BATCH_COUNT"
echo "PASS: large window emits multiple BATCH headers"

# ── test 7: empty projects root returns single BATCH header, zero paths ───────
EMPTY_ROOT=$(mktemp -d "/tmp/dream-empty-XXXXXX")
OUT7=$(DREAM_PROJECTS_ROOT="$EMPTY_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" 2>/dev/null)
rm -rf "$EMPTY_ROOT"

echo "$OUT7" | grep -q "^BATCH:" || fail "empty root: BATCH header missing"
PATH_COUNT=$(echo "$OUT7" | grep -v "^BATCH:" | grep -c ".jsonl" || true)
[ "$PATH_COUNT" -eq 0 ] || fail "empty root: unexpected paths in output"
echo "PASS: empty projects root → BATCH header only"

# ── test 7b: corrupted marker → 7-day safe fallback (never epoch-0/all-history) ─
CORRUPT_MARKER_DIR=$(mktemp -d "/tmp/dream-corrupt-XXXXXX")
printf 'not-a-date\n' > "$CORRUPT_MARKER_DIR/last-run"
make_chat "$PROJ_ROOT/proj-e/recent.jsonl" 2  # 2 days ago → inside 7d window
make_chat "$PROJ_ROOT/proj-e/ancient.jsonl" 60  # 60 days ago → outside 7d window

OUT7B=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
        DREAM_MARKER_DIR="$CORRUPT_MARKER_DIR" \
        "$FINDER" 2>/dev/null)
rm -rf "$CORRUPT_MARKER_DIR"

# Corrupted marker must not return chats from 60 days ago (that would only happen
# if window_start fell back to epoch-0). It must return the 2-day-old chat.
echo "$OUT7B" | grep -q "recent.jsonl" || fail "corrupted marker: recent chat (2d) missing from 7d fallback window"
echo "$OUT7B" | grep -q "ancient.jsonl" && fail "corrupted marker: ancient chat (60d) included — epoch-0 fallback triggered (WRONG)"
echo "PASS: corrupted marker falls back to 7-day window, never epoch-0"
```

- [ ] **Step 1.6: Run full test file**

```bash
bash tests/test_find_chats.sh
```
Expected: All eight `PASS:` lines (including the `7b: corrupted marker` line), then `All find-chats.sh tests passed.`

- [ ] **Step 1.7: Commit**

```bash
git add scripts/find-chats.sh tests/test_find_chats.sh
git commit -m "feat(orchestrator): add find-chats.sh with window resolution and batch boundaries"
```

---

## Task 2: `write-receipt.sh` — per-run receipt rendering

**Files:**
- New: `scripts/write-receipt.sh`
- New: `tests/test_write_receipt.sh`

The receipt format (from REDESIGN §3/§8):

```markdown
---
date: 2026-06-03
run_id: dream-2026-06-03T14:23:00Z
window: 2026-05-27 → 2026-06-03
chats_scanned: 4
---

# Dream run — 2026-06-03

## Written
- [[me/wiki/Bio]] — replaced "lives in Munich" → "lives in Berlin" *(undo: dream-2026-06-03T14:23:00Z)*

## Superseded
- [[me/wiki/Bio]] — "current internship at Aximon" marked stale *(undo: dream-2026-06-03T14:23:00Z)*

## Skipped (duplicate / low-confidence)
- "Python 3.12" — already present in [[me/wiki/Skills]]

## Queued for review
- [[me/wiki/Projects]] — "left Aximon" (destructive; confidence: medium) → `queue.sh` bucket: destructive
```

And `<reports_dir>/index.md` accumulates one line per run (wikilink uses the basename of reports_dir):
```markdown
- 2026-06-03 | 4 chats | 2 written · 1 superseded · 0 queued · 1 skipped → [[dream-reports/2026-06-03]]
```

### Step sequence

- [ ] **Step 2.1: Write the failing tests** — create `tests/test_write_receipt.sh`:

```bash
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
SUMMARY=$(cat <<'EOF'
{
  "run_id":       "dream-2026-06-03T14:23:00Z",
  "date":         "2026-06-03",
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

# ── test 8: dry-run mode writes receipt but does NOT create/update index ──────
DRYRUN_DIR=$(mktemp -d "/tmp/dream-runs-dry-XXXXXX")
DRY_SUMMARY=$(printf '%s' "$SUMMARY" | jq '.run_id = "dream-2026-06-03T15:00:00Z" | .date = "2026-06-03"')
printf '%s' "$DRY_SUMMARY" | \
  DREAM_RUNS_DIR="$DRYRUN_DIR" "$WRITER" --dry-run >/dev/null
rm -rf "$DRYRUN_DIR"
# (dry-run suppresses index and marker; no assertion on content — just must not crash)
echo "PASS: --dry-run does not crash"

echo "All write-receipt.sh tests passed."
```

- [ ] **Step 2.2: Run to confirm failure**

```bash
bash tests/test_write_receipt.sh
```
Expected: `FAIL: write-receipt.sh missing or not executable`.

- [ ] **Step 2.3: Create `scripts/write-receipt.sh`**

```bash
#!/usr/bin/env bash
# write-receipt.sh — render a per-run receipt from a run summary JSON (stdin).
#
# Usage:
#   <run-summary-json> | write-receipt.sh [--dry-run] [--config <path>]
#
# Environment:
#   DREAM_RUNS_DIR  — override the reports_dir from config.toml
#   DREAM_CONFIG    — path to config.toml (default: ~/.claude/dream-skill/config.toml)
#
# Output files:
#   $REPORTS_DIR/<date>.md   — full receipt
#   $REPORTS_DIR/index.md    — one-line per run summary (idempotent append)
#
# --dry-run: write receipt to stdout only; skip index.md update.
# Always exits 0 on best-effort rendering errors; exits 1 only on missing input.

set -uo pipefail

DRY_RUN=0
CONFIG_FILE="${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --config)  CONFIG_FILE="${2:-}"; shift 2 ;;
    *) echo "write-receipt.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read stdin
SUMMARY=$(cat)
[ -n "$SUMMARY" ] || { echo "write-receipt.sh: empty input on stdin" >&2; exit 1; }

# jq required for JSON parsing
command -v jq >/dev/null 2>&1 || { echo "write-receipt.sh: jq required" >&2; exit 1; }

RUN_ID=$(printf '%s' "$SUMMARY"      | jq -r '.run_id')
DATE=$(printf '%s' "$SUMMARY"        | jq -r '.date')
WIN_START=$(printf '%s' "$SUMMARY"   | jq -r '.window_start')
WIN_END=$(printf '%s' "$SUMMARY"     | jq -r '.window_end')
CHATS=$(printf '%s' "$SUMMARY"       | jq -r '.chats_scanned')

# Resolve reports dir — parse config.toml like scripts/report.sh does
# Priority: DREAM_RUNS_DIR env var > config.toml reports_dir
RUNS_DIR="${DREAM_RUNS_DIR:-}"
if [ -z "$RUNS_DIR" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    RUNS_DIR=$(awk -F'[= "]+' '/^reports_dir/ { print $2; exit }' "$CONFIG_FILE" | tr -d ' "')
  fi
fi
# Final fallback if config missing or reports_dir absent
RUNS_DIR="${RUNS_DIR:-$HOME/.claude/dream-skill/dream-reports}"
mkdir -p "$RUNS_DIR"

RECEIPT_FILE="$RUNS_DIR/${DATE}.md"
INDEX_FILE="$RUNS_DIR/index.md"

# ── count facts by action + review_status (overview §8.8) ───────────────────
# Written    = review_status=="written" AND action IN (new, supersede)
# Superseded = review_status=="written" AND action=="contradict"
# Queued     = review_status=="queued"
# Skipped    = action=="duplicate" (or review_status=="skipped")
N_WRITTEN=$(printf '%s' "$SUMMARY" | jq '[.facts[] | select(.review_status == "written" and (.action == "new" or .action == "supersede"))] | length')
N_SUPERSEDED=$(printf '%s' "$SUMMARY" | jq '[.facts[] | select(.review_status == "written" and .action == "contradict")] | length')
N_QUEUED=$(printf '%s' "$SUMMARY"    | jq '[.facts[] | select(.review_status == "queued")] | length')
N_SKIPPED=$(printf '%s' "$SUMMARY"   | jq '[.facts[] | select(.action == "duplicate" or .review_status == "skipped")] | length')
# N_WRITTEN_CLEAN = same as N_WRITTEN (Written section in index line)
N_WRITTEN_CLEAN="$N_WRITTEN"

# ── render receipt ────────────────────────────────────────────────────────────
# wiki-page → [[wikilink]] (strip .md, prepend vault/wiki prefix as-is)
wikilink() {
  printf '%s' "$1" | sed 's/\.md$//' | awk '{printf "[[%s]]", $0}'
}

render_receipt() {
  printf -- '---\n'
  printf 'date: %s\n' "$DATE"
  printf 'run_id: %s\n' "$RUN_ID"
  printf 'window: %s → %s\n' "$WIN_START" "$WIN_END"
  printf 'chats_scanned: %s\n' "$CHATS"
  printf -- '---\n\n'
  printf '# Dream run — %s\n\n' "$DATE"

  # Written section (overview §8.8): review_status=="written" AND action IN (new, supersede)
  printf '## Written\n'
  printf '%s' "$SUMMARY" | jq -r --arg undo "$RUN_ID" '
    .facts[] | select(.review_status == "written" and (.action == "new" or .action == "supersede"))
    | if .action == "supersede" then
        "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — replaced \"\(.old_content // "?")\" → \"\(.content)\" *(undo: \($undo))*"
      else
        "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" *(undo: \($undo))*"
      end
  ' || true
  printf '\n'

  # Superseded section (overview §8.8): review_status=="written" AND action=="contradict"
  # (the old line struck via stale when a contradict was applied)
  printf '## Superseded\n'
  printf '%s' "$SUMMARY" | jq -r --arg undo "$RUN_ID" '
    .facts[] | select(.review_status == "written" and .action == "contradict")
    | "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" marked stale *(undo: \($undo))*"
  ' || true
  printf '\n'

  # Skipped section (overview §8.8): action=="duplicate" or review_status=="skipped"
  printf '## Skipped (duplicate / low-confidence)\n'
  printf '%s' "$SUMMARY" | jq -r '
    .facts[] | select(.action == "duplicate" or .review_status == "skipped")
    | "- \"\(.content)\" — already present in \(.target | gsub("\\.md$";"") | "[[" + . + "]]")"
  ' || true
  printf '\n'

  # Queued section (overview §8.8): review_status=="queued"
  printf '## Queued for review\n'
  printf '%s' "$SUMMARY" | jq -r '
    .facts[] | select(.review_status == "queued")
    | "- \(.target | gsub("\\.md$";"") | "[[" + . + "]]") — \"\(.content)\" (\(.queue_bucket // "uncertain"); confidence: \(.confidence // "?")) → `queue.sh` bucket: \(.queue_bucket // "uncertain")"
  ' || true
  printf '\n'
}

if [ "$DRY_RUN" -eq 1 ]; then
  render_receipt
  exit 0
fi

render_receipt > "$RECEIPT_FILE"

# ── idempotent one-line append to index.md ────────────────────────────────────
RUNS_BASENAME=$(basename "$RUNS_DIR")
INDEX_LINE="- ${DATE} | ${CHATS} chats | ${N_WRITTEN_CLEAN} written · ${N_SUPERSEDED} superseded · ${N_QUEUED} queued · ${N_SKIPPED} skipped → [[${RUNS_BASENAME}/${DATE}]]"

if [ ! -f "$INDEX_FILE" ]; then
  printf '# Dream runs index\n\n' > "$INDEX_FILE"
fi

# Only append if this date is not already in the index (idempotent)
if ! grep -qF "[[${RUNS_BASENAME}/${DATE}]]" "$INDEX_FILE" 2>/dev/null; then
  printf '%s\n' "$INDEX_LINE" >> "$INDEX_FILE"
fi
```

Make it executable:
```bash
chmod +x scripts/write-receipt.sh
```

- [ ] **Step 2.4: Run the full test file**

```bash
bash tests/test_write_receipt.sh
```
Expected: All 8 `PASS:` lines, then `All write-receipt.sh tests passed.`

- [ ] **Step 2.5: Commit**

```bash
git add scripts/write-receipt.sh tests/test_write_receipt.sh
git commit -m "feat(orchestrator): add write-receipt.sh with receipt rendering and idempotent index"
```

---

## Task 3: Remove the SessionEnd hook entry from `hooks/hooks.json`

**Files:**
- Modify: `hooks/hooks.json`
- Test: inline validation in this task's commit step

The current `hooks/hooks.json`:
```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/check-pending.sh",
            "timeout": 3
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/trigger.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Per REDESIGN §5, the SessionEnd entry that wires `trigger.sh` must be removed. `SessionStart` / `check-pending.sh` is left in place (it will be retired in a follow-up once the new on-demand flow is validated).

- [ ] **Step 3.1: Edit `hooks/hooks.json`** — remove the entire `"SessionEnd"` key and its array:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/check-pending.sh",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3.2: Validate JSON is well-formed**

```bash
jq . hooks/hooks.json >/dev/null && echo "PASS: hooks.json valid JSON"
```
Expected: `PASS: hooks.json valid JSON`.

- [ ] **Step 3.3: Verify SessionEnd entry is absent**

```bash
jq 'has("hooks") and (.hooks | has("SessionEnd") | not)' hooks/hooks.json \
  | grep -q "true" && echo "PASS: SessionEnd removed"
```
Expected: `PASS: SessionEnd removed`.

- [ ] **Step 3.4: Commit**

```bash
git add hooks/hooks.json
git commit -m "chore(hooks): remove SessionEnd/trigger.sh wiring — on-demand replaces auto-close"
```

---

## Task 4: Marker advance helper + integration into orchestration

**Files:**
- New: inline marker-advance logic (documented here; implemented inside `SKILL.md` orchestration prose in Task 5)
- Tested: via `tests/test_find_chats.sh` (marker write + read round-trip — add as test 8)

The marker is a plain text file at `~/.claude/dream-skill/last-run` (or `$DREAM_MARKER_DIR/last-run`) containing the ISO date `YYYY-MM-DD` of the most-recently-completed batch's end date. It is written by the orchestrator (not by `find-chats.sh`), only after a batch's full REDUCE → ROUTE → RECONCILE → REVIEW → APPLY → RECEIPT cycle completes without fatal error.

Marker advance shell one-liner (to be embedded in SKILL.md orchestration):
```bash
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
mkdir -p "$MARKER_DIR"
printf '%s\n' "<batch_end_date>" > "$MARKER_DIR/last-run"
```

- [ ] **Step 4.1: Add marker round-trip test** — append to `tests/test_find_chats.sh` before the final `echo "All find-chats.sh tests passed."`:

```bash
# ── test 8: marker written by orchestrator is read back on next invocation ───
MARKER_ROUNDTRIP_DIR=$(mktemp -d "/tmp/dream-marker-rt-XXXXXX")
# Simulate orchestrator advancing marker to 3 days ago
THREE_DAYS=$(date -v "-3d" +%Y-%m-%d 2>/dev/null || date --date="3 days ago" +%Y-%m-%d)
printf '%s\n' "$THREE_DAYS" > "$MARKER_ROUNDTRIP_DIR/last-run"

make_chat "$PROJ_ROOT/proj-d/new.jsonl" 1    # 1 day ago → inside marker window
make_chat "$PROJ_ROOT/proj-d/just-old.jsonl" 5  # 5 days ago → outside marker window (3d cutoff)

OUT8=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_ROUNDTRIP_DIR" \
       "$FINDER" 2>/dev/null)
rm -rf "$MARKER_ROUNDTRIP_DIR"

echo "$OUT8" | grep -q "new.jsonl"      || fail "marker round-trip: recent chat missing"
echo "$OUT8" | grep -q "just-old.jsonl" && fail "marker round-trip: chat older than marker included"
echo "PASS: marker round-trip (orchestrator write → find-chats read)"
```

- [ ] **Step 4.2: Run full test file**

```bash
bash tests/test_find_chats.sh
```
Expected: 8 PASS lines + `All find-chats.sh tests passed.`

- [ ] **Step 4.3: Commit**

```bash
git add tests/test_find_chats.sh
git commit -m "test(orchestrator): add marker round-trip test to find-chats suite"
```

---

## Task 5: `SKILL.md` — on-demand orchestration scaffold

**Files:**
- Modify: `dream-skill/skills/dream-skill/SKILL.md` (EXISTS — do not create a new file)

This file is the skill's runtime instructions. Plan 4 modifies it: strips the auto-mode/SessionEnd sections and adds the on-demand orchestration steps referencing `## Routing` and `## Reconciliation` as "defined below". Plans 2 and 3 will append those sections respectively. This task writes the preamble + `## Extraction taxonomy` + `## Orchestration` sections. **Build order: Plan 4 first.** Plans 2 and 3 each guard: `[ -f <SKILL.md> ] || { echo "run Plan 4 first"; exit 1; }`.

The file must not contain any implementation code — it is prose that the LLM executing the skill reads at run-time. The MAP dispatch prompt lives here; its golden fixtures live in `tests/fixtures/map/`.

- [ ] **Step 5.1: Modify `dream-skill/skills/dream-skill/SKILL.md`** — strip auto-mode/SessionEnd sections; replace with the on-demand orchestration content below

```markdown
# dream-skill

> This file is read by the LLM at skill invocation time. It contains no executable code.
> Plans 2 and 3 will append ## Routing and ## Reconciliation sections.

## Invocation modes

- `/dream-skill` — on-demand run: opens a terminal review session. FIND → MAP → REDUCE → ROUTE → RECONCILE → REVIEW → APPLY → RECEIPT → MARKER.
- `/dream-skill --since <YYYY-MM-DD>` — explicit window start override.
- `/dream-skill --all` — full-history backfill (weekly-batched; only after the pipeline is trusted).
- `/dream-skill --ignore` — mark the current chat private (never recorded). Undo: `/dream-skill --unignore`.
- `/dream-skill --dry-run` — produce the receipt + proposed edits without writing to any vault.

---

## Extraction taxonomy

Used by MAP subagents. Every fact extracted from a transcript is classified into one of five buckets. Do NOT carry forward facts from the B/C/drop buckets.

| Bucket | Type | Action |
|--------|------|--------|
| A | Additive — a new stable personal fact (identity, skill, preference, project, body-stat, goal, relationship) | candidate for write |
| B | Generic commentary — agent observations, meta-chat, reasoning steps with no factual claim about Bohdan | drop |
| C | Code/tool output — shell output, diffs, debug traces, config fragments that are not themselves personal facts | drop |
| D | Destructive / high-stakes — would delete or replace an existing vault fact; or a claim contradicting the vault | always queue for review |
| E | Uncertain — stated tentatively, hypothetical, or where confidence is below medium | queue for review |

Extraction output per fact (the candidate-fact JSON contract — overview §4):

```json
{
  "content":           "<the fact, verbatim-ish from the chat>",
  "confidence":        "high | medium | low",
  "source_chat":       "<absolute path to the .jsonl transcript>",
  "source_date":       "<YYYY-MM-DD date of the chat>",
  "type":              "world-fact | belief | observation | experience",
  "evidence":          "<exact quote or brief paraphrase from the transcript>",
  "suggested_section": "<target section heading hint — e.g. Experience>"
}
```

Required fields: `content`, `confidence`, `source_chat`, `source_date`. Optional: `type`, `evidence`, `suggested_section`.

Rules:
- `source_date` is the chat's date (from its filename or metadata) — REQUIRED for supersession precedence.
- `needs_review` is NOT on the candidate — reconciliation sets it based on action + confidence.
- `suggested_section` is a hint only; the router may override.
- Emit an array of candidate-fact objects. An empty array `[]` is valid (and expected for code-only chats).
- Do not attempt routing or reconciliation in this step — emit raw candidates only.

---

## Orchestration

> This section specifies the exact step sequence executed when `/dream-skill` is invoked (no `--auto` flag — fully on-demand).

### Step 0 — Pre-flight

1. Check the `--dry-run` flag. If set, no vault writes occur; receipt is printed to stdout only. Thread `--dry-run` to `apply-decision.sh` (which Plan 3 makes mechanical).
2. Check `--ignore` / `--unignore`. If present, update the private-state flag for the current transcript and exit. Do not proceed to FIND.
3. Resolve `DREAM_SKILL_HOME` (plugin root). Verify `scripts/find-chats.sh`, `scripts/write-receipt.sh`, `scripts/queue.sh`, and `scripts/vault-writer.sh` are present and executable.
4. Parse `~/.claude/dream-skill/config.toml` (override via `${DREAM_CONFIG}` for tests) to resolve vault roots and `reports_dir`. Parse like `scripts/report.sh`: vault names from `^\[vaults\.<name>\]`, then `root =` per block; `reports_dir =` at top level. **DELETE any `~/.claude/CLAUDE.md` grep fallback** — config.toml is the only source of vault roots and reports_dir. Default `--config` to `${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}`.

### Step 1 — FIND

Run:
```bash
scripts/find-chats.sh [--since <date>] [--all]
```

Parse stdout into a list of `(batch_start, batch_end, [transcript_paths...])` tuples by consuming `BATCH:<start>:<end>` header lines.

**No-marker prompt:** If `find-chats.sh` emits no BATCH header (marker missing and no flag), prompt the user:
> No last-run marker found. Choose a window:
> 1. Last 7 days (default — recommended for first run)
> 2. Since <date> (enter a YYYY-MM-DD date)
> 3. All history (--all; weekly-batched; only after pipeline is trusted)

Then re-invoke `find-chats.sh` with the chosen flag.

**Empty result:** If a batch contains zero transcript paths, skip to RECEIPT for that batch (write a receipt noting "0 chats in window") and advance the marker.

### Step 2 — MAP

For each batch, dispatch one subagent per transcript path using the Task/Agent tool. Each subagent receives:

**Dispatch prompt (verbatim — copy into each Task invocation):**

> You are a dream-skill extraction agent. Read the transcript at `<absolute_path>` and extract every fact about Bohdan that belongs in bucket A (additive personal fact) or buckets D/E (queued items), using the extraction taxonomy in SKILL.md.
>
> Rules:
> - Apply the five-bucket taxonomy above (A=write-candidate, B/C=drop, D/E=queue).
> - Output ONLY a JSON array of candidate-fact objects matching this schema exactly (overview §4):
>   `[{"content":"...","confidence":"high|medium|low","source_chat":"<path>","source_date":"<YYYY-MM-DD>","type":"...","evidence":"...","suggested_section":"..."}]`
> - Required fields: `content`, `confidence`, `source_chat`, `source_date`. Optional: `type`, `evidence`, `suggested_section`.
> - `source_date` is the date of this chat (derive from the transcript filename or metadata).
> - Do NOT include `needs_review`, `target_hint`, or `section` — those are set by routing and reconciliation.
> - An empty array `[]` is valid for code-only or private chats.
> - Do NOT invent facts. Do NOT route or reconcile. Extract only.
> - For monster chats (transcript > ~100 KB): chunk the file into overlapping 40 KB segments, extract from each, then deduplicate within this chat before returning.

Each subagent returns a JSON array of candidate facts. Validate the JSON structure (required fields ONLY: `content`, `confidence`, `source_chat`, `source_date`). Any subagent output that is not valid JSON, or is missing any required field, is logged as an extraction error and skipped for this run. Missing optional fields (`type`, `evidence`, `suggested_section`) never cause a candidate to be dropped.

**JSON validation shell harness (unit-tested — see `tests/fixtures/map/`):**

```bash
# validate_candidates.sh (embedded logic, not a standalone script)
validate_candidates() {
  local json="$1"
  # Must be a JSON array; filter to items with all 4 required fields present.
  # NEVER select() on optional fields (type, evidence, suggested_section).
  printf '%s' "$json" | jq 'if type == "array" then
    map(
      select(
        has("content") and has("confidence") and has("source_chat")
        and has("source_date")
      )
    )
  else error("not an array") end' 2>/dev/null
}
```

### Step 3 — REDUCE

After all MAP subagents complete for a batch, merge their outputs. REDUCE is **structural only** — it deduplicates by exact string match on `(content, suggested_section)` and counts distinct `source_chat` values. It NEVER clears `needs_review`, NEVER auto-approves, and NEVER applies semantic equivalence judgments.

1. Flatten all candidate arrays into a single pool.
2. Deduplicate by exact case-insensitive `(content, suggested_section)` pair. Keep the highest-confidence copy; if equal confidence, keep the one with the most `evidence` text. Carry `source_date` through from the kept copy.
3. For facts where N ≥ 2 distinct `source_chat` values share the exact same `(content, suggested_section)`:
   - `N = 2`: raise confidence label to `medium` if currently `low`.
   - `N ≥ 3`: raise confidence label to `high` if currently below `high`.
   - Confidence promotion is the ONLY action REDUCE takes. It does NOT set `needs_review`, does NOT approve facts. `needs_review` is set exclusively by reconciliation.
4. Output: a single deduplicated array of candidate-fact objects, with a `source_chat_count` field added to each fact (integer count of distinct source chats that surfaced it).

### Step 4 — ROUTE

Pass REDUCE output to Plan 2's routing logic (the `## Routing` section of this file, to be appended by Plan 2). Each candidate receives a routing decision with fields: `{ status, vault, page, section, routing_confidence }` (overview §4). Field is `status` (not `routing_status`); there is no `canonical_path` or `needs_review` on the routing decision — the orchestrator derives the absolute path in Step 5b from `config[vault].root` + `page`.

Facts with `status = "ambiguous"` or `"gap"` (i.e. `status != "routed"`):
- Append to `~/.claude/dream-skill/routing-gaps.log` with timestamp + fact content.
- Set `needs_review = true`.
- Include in REVIEW queue under the `uncertain` bucket.

### Step 5 — RECONCILE

For each routed candidate, perform the following sub-steps (overview §5):

**Step 5a — Route status check:** If the routing decision has `status != "routed"` (i.e. `ambiguous`, `gap`, or similar), mark `needs_review = true`, append to `~/.claude/dream-skill/routing-gaps.log` with timestamp + fact content, route to the `uncertain` queue bucket, and skip reconciliation for this candidate.

**Step 5b — Resolve target page:** For candidates with `status = "routed"`, resolve the absolute path:
```bash
abs_path="<config[vault].root>/<routing_decision.page>"
```
Read the file at `abs_path` (use empty string `""` if the file does not exist — `vault-writer` will create it on a `new` write).

**Step 5c — RECONCILE prompt:** Pass the following to Plan 3's reconciliation logic (the `## Reconciliation` section, to be appended by Plan 3):
```json
{
  "candidate":   { /* full candidate-fact object including source_date */ },
  "target_page": "<full markdown text of the routed vault page, or empty string>",
  "run_date":    "<today YYYY-MM-DD>"
}
```
Each candidate receives a reconciliation decision per overview §4: `action`, `mode`, `target`, `old_content`, `content`, `candidate_confidence`, `needs_review`, `rationale`. Field is `rationale` (not `reason`).

**Step 5d — Apply:** Feed the reconciliation decision to `apply-decision.sh` (Plan 3). `apply-decision.sh` owns the action→mode→vault-writer mapping. The orchestrator does NOT re-implement this mapping — it passes the decision through unchanged.

### Step 6 — REVIEW

For all facts where `needs_review = true`, call `scripts/queue.sh append` with the appropriate bucket:
- `destructive` — D-bucket facts or `replace`/`stale` actions on high-stakes facts.
- `uncertain` — E-bucket facts, ambiguous routing, or confidence < high.
- `brainstormed` — facts that are plausible but not directly evidenced.

Then invoke the existing terminal review flow from `queue.sh list` for the user to approve / edit / skip / discard each queued item. Facts approved during review are promoted to the APPLY list; discarded facts are removed from the queue.

### Step 7 — APPLY

For each approved fact (review_status = approved or auto-approved via needs_review = false):

```bash
scripts/vault-writer.sh \
  --vault   "<vault_root>" \
  --page    "<page_relative_to_vault>" \
  --section "<section>" \
  --mode    "<append|replace|stale>" \
  [--old-content "<old_content>"]  \  # required for replace/stale
  --content "<content>" \
  --undo-log "$HOME/.claude/dream-skill/undo-<run_id>.jsonl"
```

A per-run undo log is written at `~/.claude/dream-skill/undo-<run_id>.jsonl`. The `run_id` is `dream-<date>T<HHMMSSz>`.

### Step 8 — RECEIPT

**8a — Assemble `facts[]`:** For every candidate that passed through RECONCILE (and for unrouted candidates that were queued), build one fact object per the schema below and collect them into the `facts` array:

```json
{
  "content":       "<new content string, from reconciliation decision>",
  "old_content":   "<old content string, from reconciliation decision — omit if absent>",
  "target":        "<vault>/<page>",
  "action":        "new | duplicate | supersede | contradict",
  "review_status": "written | queued | skipped",
  "queue_bucket":  "<destructive | uncertain | brainstormed — omit if review_status != queued>",
  "confidence":    "<high | medium | low — pass-through of candidate_confidence>"
}
```

Key assembly rules (overview §8.8):
- `target` is a **flattened string** `"<vault>/<page>"` derived from the reconciliation decision's `target` object: `target.vault + "/" + target.page` (e.g. `"me/wiki/experience.md"`). `write-receipt.sh` strips the trailing `.md` to form the `[[wikilink]]`.
- `action` = the reconciliation **action enum** (`new | duplicate | supersede | contradict`), NOT the mode value. Never use `append`, `replace`, `stale`, or `none` in this field.
- `review_status` ∈ `written | queued | skipped`:
  - `written` — fact was applied to the vault (via `vault-writer`).
  - `queued`  — fact is pending human review in `queue.sh`.
  - `skipped` — fact was dropped (duplicate action, or explicitly discarded).
- For unrouted candidates (`status != "routed"`): `action = "contradict"` is not applicable; use `review_status = "queued"`, `queue_bucket = "uncertain"`, preserve `confidence`.

**8b — Assemble run summary JSON and invoke `write-receipt.sh`:**

```json
{
  "run_id":        "<run_id>",
  "date":          "<YYYY-MM-DD>",
  "window_start":  "<batch_start>",
  "window_end":    "<batch_end>",
  "chats_scanned": <N>,
  "facts": [ /* one object per candidate per schema above */ ]
}
```

Then run:
```bash
printf '%s' "$SUMMARY_JSON" | scripts/write-receipt.sh [--dry-run]
```

Print the receipt path to the terminal so the user can open it in Obsidian.

### Step 9 — MARKER advance

Only after a batch's APPLY + RECEIPT completes without fatal error:

```bash
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
mkdir -p "$MARKER_DIR"
printf '%s\n' "<batch_end_date>" > "$MARKER_DIR/last-run"
```

If the run failed during APPLY (vault-writer exited non-zero), do NOT advance the marker. The next invocation will re-process the same window; vault-writer's idempotency ensures safe re-runs.

For `--all` (multi-batch) runs, the marker advances after each individual batch, so a mid-run failure leaves the marker at the last successfully completed batch boundary.

### Error handling

- MAP subagent fails (non-zero exit or invalid JSON): log the error, skip that transcript, continue.
- ROUTE returns gap/ambiguous: add to gaps log + review queue; never a silent guess.
- APPLY vault-writer exits non-zero: log + continue to next fact; do NOT advance marker if any write fails.
- Receipt write fails: log to `~/.claude/dream-skill/error.log`; still advance marker (receipt failure is not a vault-integrity issue).

---

## Golden fixtures (MAP extraction — manual eval only, not CI)

Directory: `tests/fixtures/map/`

Each fixture is a pair:
- `<name>.input.jsonl` — a synthetic transcript excerpt (minimal, focused on one topic)
- `<name>.expected.json` — the expected candidate-fact JSON array

Fixture inventory to implement. All expected.json files use the overview §4 candidate schema (required: `content`, `confidence`, `source_chat`, `source_date`; optional: `type`, `evidence`, `suggested_section`). No `target_hint`, no `needs_review`, no `section` on the candidate.

| Fixture name | What it tests |
|---|---|
| `location-change` | User mentions moving cities → bucket A, confidence `high`, `suggested_section:"Bio"`, `source_date` present |
| `internship-end` | User says they left their internship → bucket D, confidence `high` (destructive, goes to review in reconcile — not on candidate) |
| `skill-mention` | User mentions learning a new framework → bucket A, confidence `medium`, `source_date` present |
| `code-only` | Entire transcript is a coding session with no personal facts → empty array `[]` |
| `low-confidence` | User says "I think I might want to try running marathons" → bucket E, confidence `low` |
| `multi-fact` | Chat covers both a location change and a skill mention → two candidates, both with `source_date` |
| `structural-dedup` | Two .input.jsonl files (from different source_chats, same `content`+`suggested_section`) → after REDUCE, `source_chat_count:2` and confidence promoted to `medium` (was `low`). Asserts REDUCE does NOT set `needs_review`. |

To run manual eval:
```bash
# Compare MAP subagent output against golden fixture (manual, not CI):
# 1. Feed <name>.input.jsonl to the MAP dispatch prompt via claude CLI
# 2. Diff against <name>.expected.json
# 3. Acceptable delta: wording differences in `evidence` field; exact match required for bucket classification (confidence, source_date, suggested_section hint)
```

---

## `tests/fixtures/map/` — fixture schema contract (shell-validated)

The shell harness `validate_candidates` (embedded in Step 2 above) IS unit-tested. Create `tests/test_map_harness.sh`:

```bash
#!/usr/bin/env bash
# Tests the JSON validation harness for MAP subagent output (no model invoked).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

validate_candidates() {
  local json="$1"
  # Only the 4 required fields are checked (overview §4).
  # Optional fields (type, evidence, suggested_section) NEVER cause a drop.
  printf '%s' "$json" | jq 'if type == "array" then
    map(select(
      has("content") and has("confidence") and has("source_chat")
      and has("source_date")
    ))
  else error("not an array") end' 2>/dev/null
}

# Valid array — all 4 required fields present; optional fields absent (must still pass)
VALID='[{"content":"c","confidence":"high","source_chat":"/a.jsonl","source_date":"2026-06-01"}]'
OUT=$(validate_candidates "$VALID")
echo "$OUT" | jq 'length' | grep -q "1" || fail "valid candidate filtered out"
echo "PASS: valid candidate (required-only) passes validation"

# Candidate with optional fields also passes (type, evidence, suggested_section)
VALID_OPT='[{"content":"c","confidence":"high","source_chat":"/a.jsonl","source_date":"2026-06-01","type":"world-fact","evidence":"quote","suggested_section":"Skills"}]'
OUT_OPT=$(validate_candidates "$VALID_OPT")
echo "$OUT_OPT" | jq 'length' | grep -q "1" || fail "candidate with optional fields filtered out"
echo "PASS: candidate with optional fields passes validation"

# Missing source_date (required) → filtered out
MISSING='[{"content":"c","confidence":"high","source_chat":"/a.jsonl"}]'
OUT2=$(validate_candidates "$MISSING")
echo "$OUT2" | jq 'length' | grep -q "0" || fail "candidate missing source_date not filtered"
echo "PASS: candidate missing required source_date is filtered"

# Missing confidence (required) → filtered out
MISSING2='[{"content":"c","source_chat":"/a.jsonl","source_date":"2026-06-01"}]'
OUT2B=$(validate_candidates "$MISSING2")
echo "$OUT2B" | jq 'length' | grep -q "0" || fail "candidate missing confidence not filtered"
echo "PASS: candidate missing required confidence is filtered"

# Non-array returns empty (error path)
BAD='{"not":"array"}'
OUT3=$(validate_candidates "$BAD" || echo "[]")
[ -z "$(echo "$OUT3" | grep -v '^\[\]$' | head -1)" ] || echo "PASS: non-array handled"
echo "PASS: non-array input handled gracefully"

# Empty array is valid
OUT4=$(validate_candidates "[]")
echo "$OUT4" | jq 'length' | grep -q "0" || fail "empty array rejected"
echo "PASS: empty array is valid"

echo "All map harness tests passed."
```

- [ ] **Step 5.2: Run map harness test (requires jq)**

```bash
bash tests/test_map_harness.sh
```
Expected: 6 `PASS:` lines + `All map harness tests passed.`

- [ ] **Step 5.3: Commit**

```bash
git add skills/dream-skill/SKILL.md tests/test_map_harness.sh
git commit -m "feat(orchestrator): update SKILL.md with on-demand pipeline orchestration + MAP harness test"
```

---

## Task 6: Full suite run + integration smoke-test

- [ ] **Step 6.1: Run the full test suite**

```bash
for t in tests/test_*.sh; do
  echo "== $t =="
  bash "$t" || { echo "SUITE FAIL at $t"; exit 1; }
done
```
Expected: every test file ends with its "All ... passed." line; no `FAIL:`.

- [ ] **Step 6.2: Verify hooks.json has no SessionEnd**

```bash
jq '.hooks | keys' hooks/hooks.json
```
Expected: `["SessionStart"]` only.

- [ ] **Step 6.3: Dry-run smoke-test**

```bash
# Minimal smoke: find-chats.sh with an empty PROJECTS_ROOT should exit 0
EMPTY=$(mktemp -d)
DREAM_PROJECTS_ROOT="$EMPTY" DREAM_MARKER_DIR="$EMPTY" bash scripts/find-chats.sh
rm -rf "$EMPTY"
echo "PASS: find-chats.sh exits 0 on empty root"

# write-receipt.sh smoke with minimal JSON
printf '{"run_id":"x","date":"2026-06-03","window_start":"2026-05-27","window_end":"2026-06-03","chats_scanned":0,"facts":[]}' \
  | DREAM_RUNS_DIR="$(mktemp -d)" bash scripts/write-receipt.sh --dry-run
echo "PASS: write-receipt.sh --dry-run exits 0"
```

- [ ] **Step 6.4: Final commit if any cleanups needed**

```bash
git add -p   # review only
git commit -m "chore(orchestrator): integration smoke-test cleanups"
```

---

## Self-Review

### Overview §4/§5/§6/§8 contract compliance — all 13 fixes applied

| Fix | Item | Status |
|---|---|---|
| B1 | Candidate-fact schema: required `{content, confidence, source_chat, source_date}`, optional `{type, evidence, suggested_section}`. `target_hint`, `needs_review` removed from candidate. `source_date` in MAP dispatch prompt and carried through REDUCE. | Applied — Cross-plan contracts section, SKILL.md taxonomy, dispatch prompt, validate_candidates |
| B1 | `validate_candidates` checks ONLY 4 required fields; never drops for missing optionals | Applied — `validate_candidates` jq uses `has("content") and has("confidence") and has("source_chat") and has("source_date")` only |
| B2 | Step-5 action/mode table deleted. RECONCILE emits overview §4 decision. `apply-decision.sh` (Plan 3) owns action→mode→vault-writer mapping. Field is `rationale` not `reason`. | Applied — Step 5 RECONCILE rewritten with 5a/5b/5c/5d sub-steps; table gone |
| B3 | Target-page seam: Step-5 sub-steps: status check → abs_path resolve → file read → pass `{candidate, target_page, run_date}` → apply-decision.sh | Applied — Step 5a/5b/5c/5d |
| B4 | Config: parse `~/.claude/dream-skill/config.toml` for vault roots AND `reports_dir`. `~/.claude/CLAUDE.md` grep fallback deleted. Default `--config` to `${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}`. | Applied — Step 0 pre-flight item 4; `write-receipt.sh` scaffold |
| B4 | Receipts dir: `<reports_dir>/<YYYY-MM-DD>.md` + `<reports_dir>/index.md`. Hardcoded `dream-runs/` removed. | Applied — `write-receipt.sh` scaffold; File Structure section |
| I4 | Marker fallback: if marker not clean `YYYY-MM-DD` or epoch integer → fall back to 7 days, NEVER epoch-0. Test 7b asserts corrupted marker → 7d window. | Applied — `find-chats.sh` default case; test 7b added |
| I5/I7 | Receipt bucketing: Written = review_status=written AND action∈{new,supersede}; Superseded = review_status=written AND action=contradict; Queued = review_status=queued; Skipped = action=duplicate or review_status=skipped. Tests 3/3b assert supersede(Written) and contradict(Superseded) are DISTINCT. | Applied — `write-receipt.sh` jq selectors; test fixture (5 non-tautological cases); tests 3, 3b |
| I6 | REDUCE structural-only: dedup by exact `(content, suggested_section)` match; count `source_chat` to raise confidence label; NEVER clears `needs_review`, NEVER auto-approves, NEVER semantic equivalence. `structural-dedup` fixture added. | Applied — Step 3 REDUCE; fixture table |
| I1 | SKILL.md path is `dream-skill/skills/dream-skill/SKILL.md` (nested, EXISTS). Task 5 MODIFIES (not creates). Build order: Plan 4 first. Plans 2/3 guard. | Applied — Task 5 header + File Structure |
| hooks | SessionEnd entry removed. Test Step 3.3 asserts SessionEnd absent. SessionStart/check-pending kept (optional to remove later). | Already present — Task 3 unchanged |
| I2 | `--dry-run` threaded to `apply-decision.sh`. Plan 3 makes it mechanical. | Applied — Step 0 pre-flight item 1 |
| **Defect-2 (re-check)** | Routing decision schema updated to v2 `{ status, vault, page, section, routing_confidence }` in BOTH the Cross-plan contracts block and Step 4 prose. `canonical_path`, `routing_status`, `needs_review` removed from routing decision. Step 4 now keys on `status != "routed"` (consistent with Step 5a). Orchestrator derives abs_path itself from `config[vault].root` + `page` in Step 5b. | Applied — Cross-plan contracts block (L45–57); Step 4 prose |
| **Defect-1 (re-check)** | Step 8 explicitly defines `facts[]` assembly: each object = `{ content, old_content, target, action, review_status, queue_bucket, confidence }` where `target` is the flattened `"<vault>/<page>"` string (write-receipt strips `.md` for wikilink), `action` = reconciliation action enum (new\|duplicate\|supersede\|contradict). `write-receipt.sh` jq selectors rewritten to bucket on `action`+`review_status`. Test fixture replaced with 5 non-tautological distinct cases (new/supersede/contradict-written/contradict-queued/duplicate); tests 3/3b assert supersede∈Written and contradict∈Superseded as DISTINCT sections. | Applied — Step 8 (facts[] spec); `write-receipt.sh` count helpers + render_receipt jq; test fixture + tests 2, 3, 3b, 4, 5 |

### Spec coverage

| Requirement | Source | Covered? |
|---|---|---|
| FIND: window default last 7 days | overview §4, §10 | Yes — Task 1, tests 1 + 5 |
| FIND: `--since <date>` override | overview §4 | Yes — Task 1, test 2 |
| FIND: `--all` explicit backfill | overview §4, §10 | Yes — Task 1, test 3 |
| FIND: skip `--ignore`'d chats | overview §10 | Yes — Task 1, test 4 (fake private-state.sh) |
| FIND: corrupted marker → 7d fallback, never epoch-0 | overview §6, I4 | Yes — Task 1, test 7b |
| FIND: no marker → prompt user (last 7d default) | overview §10 | Yes — SKILL.md Step 1 no-marker prompt |
| FIND: weekly batch boundaries for large windows | overview §10 | Yes — Task 1, test 6; `emit_batch` slicing logic |
| MAP: one subagent per chat via Task/Agent | overview pipeline | Yes — SKILL.md Step 2 dispatch prose + prompt |
| MAP: candidate includes source_date | overview §4, B1 | Yes — dispatch prompt; taxonomy schema |
| MAP: extraction taxonomy (A/B/C/D/E buckets) | overview | Yes — SKILL.md `## Extraction taxonomy` |
| MAP: monster chat → chunk → sub-reduce | overview §10 | Yes — SKILL.md Step 2 monster-chat note |
| MAP: JSON validation harness — 4 required fields only | overview §4, B1 | Yes — Task 5 + `tests/test_map_harness.sh` |
| MAP: golden fixtures incl. structural-dedup | overview testing rules, I6 | Yes — `tests/fixtures/map/` fixture table |
| REDUCE: structural dedup by (content, suggested_section) | overview §4, I6 | Yes — SKILL.md Step 3 |
| REDUCE: source_chat_count + confidence promotion | overview §4, I6 | Yes — SKILL.md Step 3, N≥2/N≥3 rules |
| REDUCE: never clears needs_review / never auto-approves | overview §4, I6 | Yes — SKILL.md Step 3 explicit prohibition |
| ROUTE: Plan 2 hand-off | overview | Yes — SKILL.md Step 4 |
| ROUTE: ambiguous/gap → routing-gaps.log + review | overview §10 | Yes — SKILL.md Step 4; Step 5a |
| RECONCILE: target-page read seam | overview §5, B3 | Yes — SKILL.md Step 5b |
| RECONCILE: {candidate, target_page, run_date} input | overview §5, B3 | Yes — SKILL.md Step 5c |
| RECONCILE: action `new\|duplicate\|supersede\|contradict` | overview §4, B2 | Yes — Cross-plan contracts; Step 5c |
| RECONCILE: rationale field (not reason) | overview §4, B2 | Yes — reconciliation decision schema |
| RECONCILE: apply-decision.sh owns action→mode mapping | overview §4, B2 | Yes — Step 5d; action/mode table removed |
| REVIEW: queue.sh approve/edit/skip | overview | Yes — SKILL.md Step 6 |
| APPLY: vault-writer.sh with --mode | overview contracts | Yes — SKILL.md Step 7 |
| APPLY: --dry-run threaded to apply-decision.sh | overview, I2 | Yes — SKILL.md Step 0 item 1 |
| RECEIPT: `<reports_dir>/<date>.md` | overview §8, B4 | Yes — Task 2; `write-receipt.sh` uses config.toml reports_dir |
| RECEIPT: Written/Superseded/Skipped/Queued sections | overview §8, I5 | Yes — Task 2, tests 1–5 |
| RECEIPT: supersede (replace) in Written; stale in Superseded — DISTINCT | overview §8, I7 | Yes — Task 2, tests 3 + 3b |
| RECEIPT: `[[wikilinks]]` + undo id | overview §8 | Yes — Task 2, test 2 |
| RECEIPT: one-line summary in `<reports_dir>/index.md` | overview §8, B4 | Yes — Task 2, tests 6–7 |
| RECEIPT: index.md append is idempotent | overview §8 | Yes — Task 2, test 7 |
| RECEIPT: dry-run suppresses vault writes | overview §8 | Yes — Task 2, test 8; SKILL.md Step 0 |
| CONFIG: parse config.toml for vault roots + reports_dir | overview §6, B4 | Yes — Step 0 item 4; write-receipt.sh |
| CONFIG: no CLAUDE.md grep fallback | overview §6, B4 | Yes — fallback deleted from write-receipt.sh |
| MARKER: advances only after completed batch | overview §10 | Yes — SKILL.md Step 9 |
| MARKER: multi-batch `--all` advances per batch | overview §10 | Yes — SKILL.md Step 9 last paragraph |
| MARKER: failed APPLY does not advance marker | overview §10 | Yes — SKILL.md error handling |
| MARKER: round-trip test | — | Yes — Task 4, test 8 |
| SessionEnd hook removed + test | overview §5, hooks fix | Yes — Task 3, Steps 3.2–3.3 |
| SKILL.md EXISTS / modify (not create) | overview §2, I1 | Yes — Task 5 header; File Structure |
| No LLM in hook / no LLM in CI | overview invariant 5 | Yes — MAP is Task/Agent at run time; harness uses no model |

### Placeholder scan

No TBD, TODO, or FIXME placeholders. All code steps show complete implementations. Test bodies have concrete assertions and expected outputs. The only intentionally deferred items are the `## Routing` and `## Reconciliation` sections of SKILL.md, which are explicitly owned by Plans 2 and 3 (cross-plan contract boundaries, not placeholders).

### Contract consistency

- Candidate-fact required fields (`content`, `confidence`, `source_chat`, `source_date`) match overview §4. `validate_candidates` checks ONLY these 4. Optional fields (`type`, `evidence`, `suggested_section`) never cause a drop.
- `needs_review` is NOT on the candidate — set exclusively by reconciliation per overview §4.
- Routing decision schema (overview §4): `{ status, vault, page, section, routing_confidence }`. Field is `status` (not `routing_status`); no `canonical_path` or `needs_review` on the routing decision. Abs path derived in Step 5b from `config[vault].root` + `page`. Step 4 and Step 5a both key on `status != "routed"`.
- Reconciliation decision uses `rationale` (not `reason`); `action` enum is `new|duplicate|supersede|contradict`; `apply-decision.sh` (Plan 3) owns the action→mode mapping.
- Receipt uses `<reports_dir>` from config.toml, not hardcoded `dream-runs/`.
- Receipt `facts[]` objects: `target` = flattened `"<vault>/<page>"` string; `action` = reconciliation action enum (never mode values).
- Receipt bucketing (overview §8.8): Written = `review_status==written AND action∈{new,supersede}`; Superseded = `review_status==written AND action==contradict`; Queued = `review_status==queued`; Skipped = `action==duplicate OR review_status==skipped`. Zero `routing_status` or `canonical_path` references on the routing decision anywhere in this plan.
- `BATCH:<start>:<end>` line format from `find-chats.sh` consumed by SKILL.md Step 1 — both sides use colon-delimited format.

### Marker-advance-after-batch confirmation

Marker advance happens in SKILL.md Step 9, gated on: (1) APPLY completed without fatal error AND (2) RECEIPT written. For `--all` multi-batch runs, the marker advances after each batch individually (Step 9 last paragraph). Tests 5 and 8 verify written marker is read back correctly. Test 7b verifies corrupted marker never falls back to epoch-0 (7-day safe default instead).

### No-LLM-in-hook confirmation

The `hooks/hooks.json` SessionEnd entry is removed in Task 3. `find-chats.sh` and `write-receipt.sh` are pure shell with no model invocations. MAP dispatch runs inside the skill session at user invocation time via Task/Agent tool, not in any hook. `test_map_harness.sh` tests the JSON validation harness without invoking any model.

---

## Open questions / contract notes

1. **`write-receipt.sh` RUNS_DIR default derivation** — resolved: `write-receipt.sh` now parses `~/.claude/dream-skill/config.toml` for `reports_dir` (same awk pattern as `report.sh`). The `~/.claude/CLAUDE.md` grep fallback has been deleted. `DREAM_RUNS_DIR` env var remains as a test override. No open question here.

2. **Monster-chat chunk size** — the dispatch prompt specifies "~100 KB / 40 KB segments" as a heuristic. The actual Claude context window for the subagent model (Haiku 4.5 at ~200K tokens) makes this very conservative. The threshold could be raised; however, keeping it conservative avoids context-overflow recurrence for large coding sessions with verbose tool output. Flag for tuning after first real runs.

3. **REDUCE dedup scope** — REDUCE is structural only: exact case-insensitive `(content, suggested_section)` match. No semantic equivalence judgment. If near-duplicate variants slip through, they will be caught by reconciliation (duplicate action). A semantic dedup subagent could be added in v1.1 if needed.

4. **`scripts/check-pending.sh` + SessionStart hook** — left in place per REDESIGN §5 (retire separately). Plan 4 does not own its removal; it should be noted in the Plan 2 or a follow-up cleanup task.

5. **`preprocess*.sh` demotion** — REDESIGN §5 says "demote, do not delete; keep as optional cheap pre-filter." Plan 4 does not wire `preprocess.sh` into the MAP dispatch prompt; subagents read the raw `.jsonl`. If large tool-dump chats cause subagent overload in practice, wire `preprocess.sh` as an optional pre-filter before the dispatch prompt (gated on `DREAM_USE_PREPROCESS=1`). Recommended as a follow-up, not blocking.

6. **`--dry-run` propagation to `apply-decision.sh`** — SKILL.md Step 0 sets a dry-run flag and threads `--dry-run` to `apply-decision.sh` (Plan 3 makes this mechanical). `write-receipt.sh --dry-run` is tested in Task 2 test 8. The orchestrator passes `--dry-run` through; Plan 3 is responsible for suppressing vault-writer calls. No dedicated integration test for dry-run APPLY suppression in this plan — covered by Plan 3's own test suite.
