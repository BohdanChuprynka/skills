# Plan 3 — Reconciler: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Reconciler — the LLM judgment layer that takes a routed candidate-fact and the current content of its target page, then produces a reconciliation-decision JSON specifying exactly what vault-writer should do (or not do). Also delivers the deterministic `apply-decision.sh` dispatcher that translates a reconciliation-decision into the correct `vault-writer.sh` invocation and, when warranted, a `queue.sh` entry.

**Architecture:** The Reconciler is a two-layer component:

1. **LLM judgment layer** — a `## Reconciliation` section added to `SKILL.md` containing the prompt that the orchestrator (Plan 4) invokes per candidate. Input: `{ candidate, target_page, run_date }` — the orchestrator (Plan 4 §5) reads the target page and supplies it; the LLM does NOT read the page itself. Output: reconciliation-decision JSON. This layer encodes the four action categories, precedence rules, and volatility-driven behaviour.
2. **Deterministic dispatcher** — `scripts/apply-decision.sh`. Input: reconciliation-decision JSON. Output: calls `vault-writer.sh` with the correct `--mode` flag and, for `needs_review:true` decisions, also enqueues via `queue.sh`. This is the only shell-testable surface in Plan 3.

**Tech Stack:** Bash (`set -euo pipefail`), `jq` for JSON parsing, plain-shell tests mirroring `tests/test_vault_writer.sh` style.

**Repo root:** `/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill`

---

## File Structure

**New files this plan owns (no other plan touches these):**

- `skills/dream-skill/SKILL.md` — append `## Reconciliation` section (nested path; guard: `[ -f … ] || exit`)
- `tests/fixtures/reconcile/` — golden fixture directory (five JSON files)
  - `new.json`
  - `duplicate.json`
  - `supersede.json`
  - `contradict.json`
  - `new_low_confidence.json`
- `scripts/apply-decision.sh` — deterministic decision→vault-writer dispatcher (SOLE owner of action→mode mapping)
- `tests/test_apply_decision.sh` — plain-shell unit tests for the dispatcher (6 tests)

**Modified files (one existing file):**

- `scripts/vault-writer.sh` — add `--dry-run` flag only (Task 4); all other behaviour unchanged

---

## Task 1: `## Reconciliation` section in `SKILL.md`

### Why this section exists

The orchestrator (Plan 4) invokes this prompt once per routed candidate-fact, after routing has resolved a target page. The orchestrator resolves the target page's absolute path from config (§5 of the overview), reads the file (empty string if it doesn't exist), and passes the full page text as `target_page` — the LLM does NOT read the page itself. The LLM receives `{ candidate, target_page, run_date }` and returns a reconciliation-decision JSON. All judgment lives here; the deterministic dispatcher (Task 3) only routes the decision onward.

### Prompt design principles

- Input is **fully self-contained** per call: `{ candidate, target_page, run_date }`. The `target_page` (full markdown text) and `run_date` are **supplied by the orchestrator** (Plan 4 §5 seam) — the LLM does not fetch or read any file. No session memory is assumed.
- The `candidate` uses the §4 schema: read `suggested_section` (NOT `section`) and `source_date` (REQUIRED — guaranteed present; the precedence logic depends on it).
- Output is **one JSON object only**, matching the reconciliation-decision contract exactly.
- Precedence, volatility, and the four action definitions are encoded directly in the prompt so the LLM does not need to consult outside sources.

---

- [ ] **Step 1: Append `## Reconciliation` to `SKILL.md`**

SKILL.md path: `dream-skill/skills/dream-skill/SKILL.md` (nested). This section is appended AFTER Plan 4 has restructured SKILL.md and Plan 2 has appended `## Routing`. Guard required:

```bash
[ -f dream-skill/skills/dream-skill/SKILL.md ] || { echo "Run Plan 4 first"; exit 1; }
```

Append the following section verbatim to the end of `dream-skill/skills/dream-skill/SKILL.md`:

````markdown
## Reconciliation

> This section is the LLM prompt executed by the orchestrator (Plan 4) once per routed
> candidate-fact. Input: a `candidate` JSON object, the full text of the `target_page`
> (as a string), and the `run_date` (ISO-8601, today's date). Output: one JSON object
> matching the reconciliation-decision contract. Emit the JSON only — no prose.

### Input schema

```json
{
  "candidate": {
    "content":          "Cleveland Clinic internship confirmed for Jun–Aug 2026",
    "type":             "world-fact | belief | observation | experience",
    "confidence":       "high | medium | low",
    "evidence":         "short quote/paraphrase from the source chat",
    "source_chat":      "<session-id>",
    "source_date":      "2026-06-01",
    "suggested_section": "Experience"
  },
  "target_page": "<full markdown text of the routed vault page>",
  "run_date":    "2026-06-03"
}
```

### Output schema (reconciliation-decision)

```json
{
  "action":               "new | duplicate | supersede | contradict",
  "mode":                 "append | replace | stale | none",
  "target": {
    "vault":   "<vault-name>",
    "page":    "<relative path, e.g. wiki/experience.md>",
    "section": "<H2 heading text>"
  },
  "old_content":          "<exact existing line text, omit key for 'new' and 'duplicate'>",
  "content":              "<the new fact line to write, omit key for 'duplicate'>",
  "candidate_confidence": "high | medium | low",
  "needs_review":         true,
  "rationale":            "<one sentence explaining the classification>"
}
```

Field notes (from v2 §4):
- `action` enum is EXACTLY `new|duplicate|supersede|contradict` (never mode-values).
- `mode` is `append|replace|stale|none` — use `none` for `duplicate`.
- `candidate_confidence` is a REQUIRED pass-through of the candidate's `confidence` field; it drives queue bucketing in `apply-decision.sh`.
- Field is `rationale` (not `reason`).
- **`needs_review` rule:** `true` for everything EXCEPT `action: new` AND `candidate_confidence: high`. All destructive edits, all contradictions, and all low/medium-confidence new facts go to review.

### Action definitions and mode mapping

| Action      | When to use                                                        | mode   | needs_review |
|-------------|--------------------------------------------------------------------|--------|-------------|
| `new`       | The fact (or one semantically equivalent) is absent from the page | append | false if confidence=high; true otherwise |
| `duplicate` | An existing line carries the same meaning (wording may differ)    | none   | false |
| `supersede` | Same subject+attribute, candidate value is newer/more specific    | replace| true |
| `contradict`| Conflicting claims, winner unclear (no clear date precedence)     | stale  | true |

**For `duplicate`:** emit `"mode": "none"` and `"content": ""` (empty string) as placeholders — `none` is the correct mode value per v2 §4. The dispatcher skips any write because the fact is already represented. Do NOT omit the `mode` and `content` keys — the schema validator requires all fields.

**For `contradict`:** `mode` is `stale` (the existing line is struck through); the new candidate is queued for human review but NOT written. Set `old_content` to the conflicting existing line.

### Precedence rules (apply in order)

1. **User's words in the source chat always win** — if the candidate came from a direct user statement in the session, treat it as authoritative over any existing vault claim.
2. **Newer `source_date` beats older vault content** — when both a candidate and an existing line reference the same subject+attribute, the one with the later date supersedes. If the existing line has no date marker, treat it as older.
3. **`confidence: low` (brainstormed/hypothetical) never auto-writes** — force `needs_review: true` regardless of action.
4. **Ambiguous precedence → `contradict`** — when you cannot determine which claim is more recent or authoritative, classify as `contradict`, not `supersede`.

### Volatility guidance

The target page's frontmatter or the vault's `CLAUDE.md` may carry a `volatility` tag (`VOLATILE` or `STABLE`). Use it as follows:

- **VOLATILE page** (e.g. `goals/now`, current-project status, active sprint): actively scan every existing line in the candidate's section for a semantically stale version of the same fact. When found, classify as `supersede` rather than `new`.
- **STABLE page** (e.g. past experience, education, completed projects): prefer `new` (append) unless an exact or near-exact duplicate is present. Do not hunt for supersession targets.
- **No tag / unknown**: treat as STABLE.

### Semantic equivalence (duplicate detection)

Two lines are **semantically equivalent** if a competent reader would consider them to convey the same fact about the same subject, even if the wording differs. Examples:

- `"interned at Cleveland Clinic"` ≅ `"Cleveland Clinic internship Jun–Aug 2026"` → **duplicate** (same role, same org)
- `"lives in Berlin"` ≠ `"lives in Munich"` → same attribute, different value → **supersede** or **contradict**
- `"knows Python"` ≅ `"Python (proficient)"` → **duplicate**
- `"interested in ML"` ≠ `"working on ML project"` → different claim level → **new** (additive, not a duplicate)

### Worked examples

**Example A — new (absent fact, high confidence)**
```
candidate.content = "Passed AWS Solutions Architect exam 2026-05"
candidate.confidence = "high"
target_page (skills.md) has no mention of AWS certification
→ action: "new", mode: "append", needs_review: false
```

**Example B — duplicate**
```
candidate.content = "Python (proficient)"
target_page (skills.md) already contains line "- knows Python"
→ action: "duplicate", mode: "none", content: "", needs_review: false
```

**Example C — supersede**
```
candidate.content = "lives in Munich (moved 2026-06)"
candidate.source_date = "2026-06-03"
target_page (bio.md) contains "- lives in Berlin" (no date marker → treated as older)
→ action: "supersede", mode: "replace",
   old_content: "lives in Berlin",
   content: "lives in Munich (moved 2026-06)",
   needs_review: true
```

**Example D — contradict**
```
candidate.content = "primary language is TypeScript"
candidate.source_date = "2026-05-10"
target_page (skills.md) contains "- primary language is Python (since 2023)"
Both have dates; TypeScript claim is newer but Python claim is qualified "since 2023";
winner is genuinely unclear → classify as contradict
→ action: "contradict", mode: "stale",
   old_content: "primary language is Python (since 2023)",
   needs_review: true
```

### Output rules

- Emit **one JSON object only**. No markdown fences, no prose, no extra keys.
- `target.vault`, `target.page`, and `target.section` are passed through verbatim from the routing decision that preceded this step (Plan 2 output).
- `rationale` must be a single sentence referencing the specific rule applied.
- Never emit `action: "new"` with `needs_review: false` when `confidence` is `medium` or `low`.
- If the target page is **empty or does not exist**, treat every candidate as `action: "new"`.
````

- [ ] **Step 2: Verify the section was appended correctly**

Check that `SKILL.md` now contains the `## Reconciliation` heading and that the JSON schemas inside it are syntactically valid by running (from the `dream-skill/` repo root):

```bash
SKILL="skills/dream-skill/SKILL.md"
grep -n "## Reconciliation" "$SKILL"
python3 -c "
import re, sys
text = open('$SKILL').read()
# extract JSON blocks and validate each
blocks = re.findall(r'\`\`\`json\n(.*?)\`\`\`', text, re.DOTALL)
import json
for i, b in enumerate(blocks):
    # skip blocks with placeholder pipes (table-like)
    if '|' in b: continue
    try:
        json.loads(b)
    except Exception as e:
        print(f'Block {i}: INVALID: {e}')
        sys.exit(1)
print('All JSON blocks valid')
"
```

Expected: `## Reconciliation` found, `All JSON blocks valid`.

---

## Task 2: Golden fixtures — `tests/fixtures/reconcile/`

These fixtures document the expected model behaviour for each of the four action categories. They are used for manual/eval acceptance testing, not CI. Format: one JSON file per case, each containing `candidate`, `target_page_snapshot` (the full page text the model sees), and `expected_decision` (the exact reconciliation-decision JSON the model should produce).

---

- [ ] **Step 1: Create the fixtures directory**

```bash
mkdir -p tests/fixtures/reconcile
```

- [ ] **Step 2: Write `tests/fixtures/reconcile/new.json`**

```json
{
  "_comment": "Absent fact, high confidence → new/append, needs_review:false",
  "candidate": {
    "content": "Passed AWS Solutions Architect exam 2026-05",
    "type": "world-fact",
    "confidence": "high",
    "evidence": "\"I just passed my AWS SA cert last week\"",
    "source_chat": "session-abc123",
    "source_date": "2026-05-28",
    "suggested_section": "Certifications"
  },
  "target_page_snapshot": "# Skills\n\n## Languages\n\n- Python (proficient)\n- TypeScript (proficient)\n\n## Frameworks\n\n- React\n- FastAPI\n",
  "run_date": "2026-06-03",
  "expected_decision": {
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
    "rationale": "Fact is absent from the target page and candidate confidence is high, so a direct append is warranted."
  }
}
```

- [ ] **Step 3: Write `tests/fixtures/reconcile/duplicate.json`**

```json
{
  "_comment": "Semantically equivalent fact already present → duplicate/skip",
  "candidate": {
    "content": "Python (proficient)",
    "type": "world-fact",
    "confidence": "high",
    "evidence": "\"yeah I use Python day to day\"",
    "source_chat": "session-abc124",
    "source_date": "2026-06-01",
    "suggested_section": "Languages"
  },
  "target_page_snapshot": "# Skills\n\n## Languages\n\n- knows Python\n- TypeScript (proficient)\n",
  "run_date": "2026-06-03",
  "expected_decision": {
    "action": "duplicate",
    "mode": "none",
    "target": {
      "vault": "me",
      "page": "wiki/skills.md",
      "section": "Languages"
    },
    "content": "",
    "candidate_confidence": "high",
    "needs_review": false,
    "rationale": "The existing line 'knows Python' is semantically equivalent to the candidate; no write is needed."
  }
}
```

- [ ] **Step 4: Write `tests/fixtures/reconcile/supersede.json`**

```json
{
  "_comment": "Same subject+attribute, candidate is newer → supersede/replace, needs_review:true",
  "candidate": {
    "content": "lives in Munich (moved 2026-06)",
    "type": "world-fact",
    "confidence": "high",
    "evidence": "\"I moved to Munich at the start of June\"",
    "source_chat": "session-abc125",
    "source_date": "2026-06-03",
    "suggested_section": "Bio"
  },
  "target_page_snapshot": "# Bio\n\n## Bio\n\n- lives in Berlin\n- originally from Kyiv\n",
  "run_date": "2026-06-03",
  "expected_decision": {
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
    "rationale": "Candidate's source_date (2026-06-03) is newer than the undated vault line; same subject+attribute (location) → supersede with replace."
  }
}
```

- [ ] **Step 5: Write `tests/fixtures/reconcile/contradict.json`**

```json
{
  "_comment": "Conflicting claims, winner unclear → contradict/stale + queue, needs_review:true",
  "candidate": {
    "content": "primary language is TypeScript",
    "type": "belief",
    "confidence": "high",
    "evidence": "\"these days TypeScript is really my main language\"",
    "source_chat": "session-abc126",
    "source_date": "2026-05-10",
    "suggested_section": "Languages"
  },
  "target_page_snapshot": "# Skills\n\n## Languages\n\n- primary language is Python (since 2023)\n- TypeScript (proficient)\n",
  "run_date": "2026-06-03",
  "expected_decision": {
    "action": "contradict",
    "mode": "stale",
    "target": {
      "vault": "me",
      "page": "wiki/skills.md",
      "section": "Languages"
    },
    "old_content": "primary language is Python (since 2023)",
    "content": "primary language is TypeScript",
    "candidate_confidence": "high",
    "needs_review": true,
    "rationale": "Both claims reference the same attribute (primary language); the 'since 2023' qualifier on the existing line makes precedence unclear, so contradiction is flagged for human review."
  }
}
```

- [ ] **Step 6: Write `tests/fixtures/reconcile/new_low_confidence.json`**

This extra fixture covers the invariant that `confidence: low` always sets `needs_review: true` even for `new` actions.

```json
{
  "_comment": "New fact but low confidence (brainstormed) → new/append, needs_review:true",
  "candidate": {
    "content": "might pivot to product management",
    "type": "belief",
    "confidence": "low",
    "evidence": "\"I've been thinking maybe PM could be interesting\"",
    "source_chat": "session-abc127",
    "source_date": "2026-06-02",
    "suggested_section": "Goals"
  },
  "target_page_snapshot": "# Goals\n\n## Goals\n\n- become a strong ML engineer\n",
  "run_date": "2026-06-03",
  "expected_decision": {
    "action": "new",
    "mode": "append",
    "target": {
      "vault": "me",
      "page": "wiki/goals.md",
      "section": "Goals"
    },
    "content": "might pivot to product management",
    "candidate_confidence": "low",
    "needs_review": true,
    "rationale": "Fact is absent from the page but candidate confidence is low (hypothetical), so human review is required before writing."
  }
}
```

### Acceptance criteria for golden fixtures

These fixtures are **not run in CI**. They are used for manual eval: before releasing this plan's implementation, run the reconciliation prompt against each fixture's `{candidate, target_page_snapshot, run_date}` and verify the model output matches `expected_decision` on the fields that matter (`action`, `mode`, `needs_review`, `old_content` when present). Tolerate minor wording differences in `rationale`. Log results in a `tests/fixtures/reconcile/EVAL-LOG.md` file when the eval is run.

Documented acceptance step:

```bash
# For each fixture, manually invoke the reconciliation step in a Claude Code session:
# 1. Load the fixture's candidate + target_page_snapshot + run_date
# 2. Send to Claude with the ## Reconciliation prompt
# 3. Compare output to expected_decision
# 4. Log pass/fail + any deviation in tests/fixtures/reconcile/EVAL-LOG.md
```

---

## Task 3: `scripts/apply-decision.sh`

### Why include this script

Including `apply-decision.sh` earns its place on two grounds:

1. **Testability**: the JSON→vault-writer mapping is deterministic and belongs in a unit-tested shell script, not repeated inline in the orchestrator prompt. Without it, four independent action branches with different flag combinations live scattered in SKILL.md's prose — fragile and invisible to the test harness.
2. **Single dispatch point**: every future change to the vault-writer interface (new flags, mode renames) is isolated to one file. Plan 4's orchestrator calls `apply-decision.sh` as a black box.

The alternative — orchestrator calls vault-writer directly from decision JSON — would push deterministic flag-mapping into LLM-generated prose, making it untestable.

### Specification

**Input:** path to a reconciliation-decision JSON file, plus the vault root and undo-log path.

**Output:** zero or more `vault-writer.sh` invocations + zero or one `queue.sh append` call. Exits 0 on success, non-zero on failure.

**Action dispatch table:**

| `action`    | vault-writer call                                        | queue.sh call |
|-------------|----------------------------------------------------------|---------------|
| `new`       | `--mode append --content <content>`                      | only if `needs_review:true` (uncertain bucket) |
| `duplicate` | none (skip)                                              | none |
| `supersede` | `--mode replace --content <content> --old-content <old>` | always (`needs_review` is always true) |
| `contradict`| `--mode stale --old-content <old>`                       | always (`needs_review` is always true); new content queued, not written |

**For `contradict`:** the `--mode stale` call marks the old line as superseded; the new `content` is NOT written to the vault — it is enqueued only. This matches the spec: "flag, never auto-resolve".

**Bucket mapping** for `queue.sh append` (derived from `candidate_confidence` — do NOT hardcode):
- `supersede` → `--bucket destructive`
- `contradict` → `--bucket destructive`
- `new` with `needs_review:true` and `candidate_confidence: low` → `--bucket brainstormed`
- `new` with `needs_review:true` and `candidate_confidence: medium` → `--bucket uncertain`

---

- [ ] **Step 1: Write the failing tests** — create `tests/test_apply_decision.sh`

```bash
#!/usr/bin/env bash
# Test: apply-decision.sh maps reconciliation-decision JSON → correct vault-writer/queue calls
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLY="$SCRIPT_DIR/../scripts/apply-decision.sh"
WRITER="$SCRIPT_DIR/../scripts/vault-writer.sh"
QUEUE="$SCRIPT_DIR/../scripts/queue.sh"

[ -x "$APPLY" ] || { echo "FAIL: apply-decision.sh missing or not executable"; exit 1; }

# Setup mock vault in tmp
VAULT=$(mktemp -d "/tmp/dream-apply-test-XXXXXX")
trap 'rm -rf "$VAULT"' EXIT

mkdir -p "$VAULT/wiki"
UNDO_LOG="$VAULT/undo.jsonl"
DECISION_FILE="$VAULT/decision.json"

fail() { echo "FAIL: $*"; exit 1; }

# --- Test 1: new (high confidence) → append call, no queue entry ---

cat > "$VAULT/wiki/skills.md" <<'EOF'
# Skills

## Certifications

- holds CKAD cert
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "Passed AWS Solutions Architect exam 2026-05",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Absent fact, high confidence."
}
EOF

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "Passed AWS Solutions Architect" "$VAULT/wiki/skills.md" \
  || fail "new: content not appended"
[ ! -f "$DREAM_QUEUE_FILE" ] || ! grep -q "AWS Solutions Architect" "$DREAM_QUEUE_FILE" \
  || fail "new high-confidence: should not be queued"
echo "PASS: new action → appends content, no queue entry"

# --- Test 2: duplicate → no write ---

PAGE_BEFORE=$(cat "$VAULT/wiki/skills.md")

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "duplicate",
  "mode": "none",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Certifications" },
  "content": "",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Already present."
}
EOF

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

PAGE_AFTER=$(cat "$VAULT/wiki/skills.md")
[ "$PAGE_BEFORE" = "$PAGE_AFTER" ] || fail "duplicate: page was modified when it should not be"
echo "PASS: duplicate action → no write"

# --- Test 3: supersede → replace call with old_content ---

cat > "$VAULT/wiki/bio.md" <<'EOF'
# Bio

## Bio

- lives in Berlin
- originally from Kyiv
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "supersede",
  "mode": "replace",
  "target": { "vault": "me", "page": "wiki/bio.md", "section": "Bio" },
  "old_content": "lives in Berlin",
  "content": "lives in Munich (moved 2026-06)",
  "candidate_confidence": "high",
  "needs_review": true,
  "rationale": "Newer source_date wins."
}
EOF

QUEUE_FILE=$(mktemp "/tmp/dream-queue-XXXXXX.md")
export DREAM_QUEUE_FILE="$QUEUE_FILE"

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "lives in Munich" "$VAULT/wiki/bio.md" \
  || fail "supersede: new content not present"
grep -q "lives in Berlin" "$VAULT/wiki/bio.md" \
  && fail "supersede: old content still present"
grep -q "lives in Munich" "$QUEUE_FILE" \
  || fail "supersede: not enqueued for review"
grep -qi "destructive" "$QUEUE_FILE" \
  || fail "supersede: queue bucket must be 'destructive'"
echo "PASS: supersede action → replace call + queue entry (destructive bucket)"

# --- Test 4: contradict → stale call + queue entry, new content NOT written ---

cat > "$VAULT/wiki/skills.md" <<'EOF'
# Skills

## Languages

- primary language is Python (since 2023)
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "contradict",
  "mode": "stale",
  "target": { "vault": "me", "page": "wiki/skills.md", "section": "Languages" },
  "old_content": "primary language is Python (since 2023)",
  "content": "primary language is TypeScript",
  "candidate_confidence": "high",
  "needs_review": true,
  "rationale": "Winner unclear."
}
EOF

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "~~primary language is Python" "$VAULT/wiki/skills.md" \
  || fail "contradict: old line not struck through"
grep -q "primary language is TypeScript" "$VAULT/wiki/skills.md" \
  && fail "contradict: new content must NOT be written to vault"
grep -q "primary language is TypeScript" "$QUEUE_FILE" \
  || fail "contradict: new content not enqueued for review"
grep -qi "destructive" "$QUEUE_FILE" \
  || fail "contradict: queue bucket must be 'destructive'"
echo "PASS: contradict action → stale call + queue entry (destructive bucket), new content not in vault"

# --- Test 5: new with needs_review:true → append + queue entry ---

cat > "$VAULT/wiki/goals.md" <<'EOF'
# Goals

## Goals

- become a strong ML engineer
EOF

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/goals.md", "section": "Goals" },
  "content": "might pivot to product management",
  "candidate_confidence": "low",
  "needs_review": true,
  "rationale": "Low confidence, brainstormed fact."
}
EOF

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG"

grep -q "might pivot to product management" "$VAULT/wiki/goals.md" \
  && fail "new needs_review:true: should NOT auto-write to vault"
grep -q "pivot to product management" "$QUEUE_FILE" \
  || fail "new needs_review:true: should be enqueued"
grep -qi "brainstormed" "$QUEUE_FILE" \
  || fail "new low-confidence: queue bucket must be 'brainstormed'"
echo "PASS: new needs_review:true (low confidence) → not written, queued in brainstormed bucket"

# --- Test 6: --dry-run → vault and queue both unchanged ---

VAULT_SNAPSHOT=$(cat "$VAULT/wiki/goals.md")
QUEUE_SNAPSHOT=$(cat "$QUEUE_FILE" 2>/dev/null || true)

cat > "$DECISION_FILE" <<'EOF'
{
  "action": "new",
  "mode": "append",
  "target": { "vault": "me", "page": "wiki/goals.md", "section": "Goals" },
  "content": "dry-run sentinel fact",
  "candidate_confidence": "high",
  "needs_review": false,
  "rationale": "Dry-run test — must not write."
}
EOF

"$APPLY" --vault "$VAULT" --decision "$DECISION_FILE" --undo-log "$UNDO_LOG" --dry-run

VAULT_AFTER=$(cat "$VAULT/wiki/goals.md")
QUEUE_AFTER=$(cat "$QUEUE_FILE" 2>/dev/null || true)
[ "$VAULT_SNAPSHOT" = "$VAULT_AFTER" ] || fail "--dry-run: vault page was modified"
[ "$QUEUE_SNAPSHOT" = "$QUEUE_AFTER" ] || fail "--dry-run: queue was modified"
grep -q "dry-run sentinel fact" "$VAULT/wiki/goals.md" \
  && fail "--dry-run: sentinel content must not be in vault"
echo "PASS: --dry-run → vault and queue byte-identical after apply"

rm -f "$QUEUE_FILE"

echo ""
echo "All apply-decision.sh tests passed."
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bash tests/test_apply_decision.sh
```

Expected: FAIL — `apply-decision.sh` does not exist yet. (Tests 1–6 are expected to fail.)

- [ ] **Step 3: Write `scripts/apply-decision.sh`**

```bash
#!/usr/bin/env bash
# apply-decision.sh — maps a reconciliation-decision JSON to vault-writer.sh + queue.sh calls.
# SOLE OWNER of the action→mode→vault-writer mapping (overview §4, §8.2).
# Usage:
#   apply-decision.sh --vault <vault-root> --decision <json-file> --undo-log <path>
#                     [--writer <path-to-vault-writer.sh>]
#                     [--queue  <path-to-queue.sh>]
#                     [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="${WRITER_PATH:-$SCRIPT_DIR/vault-writer.sh}"
QUEUE_SCRIPT="${QUEUE_PATH:-$SCRIPT_DIR/queue.sh}"

VAULT=""
DECISION_FILE=""
UNDO_LOG=""
DRY_RUN=0

die() { echo "apply-decision: $*" >&2; exit 1; }

# --- arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --vault)     VAULT="$2";         shift 2 ;;
    --decision)  DECISION_FILE="$2"; shift 2 ;;
    --undo-log)  UNDO_LOG="$2";      shift 2 ;;
    --writer)    WRITER="$2";        shift 2 ;;
    --queue)     QUEUE_SCRIPT="$2";  shift 2 ;;
    --dry-run)   DRY_RUN=1;          shift   ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$VAULT" ]         || die "missing --vault"
[ -n "$DECISION_FILE" ] || die "missing --decision"
[ -n "$UNDO_LOG" ]      || die "missing --undo-log"
[ -f "$DECISION_FILE" ] || die "decision file not found: $DECISION_FILE"
[ -x "$WRITER" ]        || die "vault-writer not executable: $WRITER"
[ -x "$QUEUE_SCRIPT" ]  || die "queue.sh not executable: $QUEUE_SCRIPT"

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- parse decision ---
ACTION=$(jq -r '.action'                        "$DECISION_FILE")
PAGE=$(jq -r '.target.page'                     "$DECISION_FILE")
SECTION=$(jq -r '.target.section'               "$DECISION_FILE")
CONTENT=$(jq -r '.content // ""'                "$DECISION_FILE")
OLD_CONTENT=$(jq -r '.old_content // ""'        "$DECISION_FILE")
NEEDS_REVIEW=$(jq -r '.needs_review'            "$DECISION_FILE")
RATIONALE=$(jq -r '.rationale'                  "$DECISION_FILE")
CONFIDENCE=$(jq -r '.candidate_confidence // "medium"' "$DECISION_FILE")

# Validate action
case "$ACTION" in
  new|duplicate|supersede|contradict) ;;
  *) die "unknown action: $ACTION" ;;
esac

# --dry-run: print intended change, touch nothing, exit 0
if [ "$DRY_RUN" = "1" ]; then
  echo "apply-decision [dry-run]: action=$ACTION page=$PAGE section=$SECTION confidence=$CONFIDENCE"
  echo "  content:     $CONTENT"
  echo "  old_content: $OLD_CONTENT"
  echo "  needs_review: $NEEDS_REVIEW"
  exit 0
fi

# --- derive queue bucket from candidate_confidence ---
bucket_for_new() {
  case "$CONFIDENCE" in
    low)    echo "brainstormed" ;;
    medium) echo "uncertain"    ;;
    *)      echo "uncertain"    ;;  # fallback for high (shouldn't reach queue)
  esac
}

# --- dispatch ---

case "$ACTION" in

  new)
    if [ "$NEEDS_REVIEW" = "true" ]; then
      # Low/medium confidence — queue only, do NOT write to vault
      "$QUEUE_SCRIPT" append \
        --bucket   "$(bucket_for_new)" \
        --title    "$CONTENT" \
        --evidence "$RATIONALE" \
        --confidence "$CONFIDENCE" \
        --target   "$PAGE#$SECTION"
    else
      # High confidence — append to vault
      "$WRITER" \
        --vault    "$VAULT" \
        --page     "$PAGE" \
        --section  "$SECTION" \
        --content  "$CONTENT" \
        --mode     append \
        --undo-log "$UNDO_LOG"
    fi
    ;;

  duplicate)
    # Nothing to do — fact already represented in the vault
    : ;;

  supersede)
    # Replace old line in vault, then queue for human confirmation (always destructive)
    "$WRITER" \
      --vault       "$VAULT" \
      --page        "$PAGE" \
      --section     "$SECTION" \
      --content     "$CONTENT" \
      --mode        replace \
      --old-content "$OLD_CONTENT" \
      --undo-log    "$UNDO_LOG"

    "$QUEUE_SCRIPT" append \
      --bucket     "destructive" \
      --title      "$CONTENT" \
      --evidence   "Superseded: $OLD_CONTENT → $CONTENT. $RATIONALE" \
      --confidence "$CONFIDENCE" \
      --target     "$PAGE#$SECTION"
    ;;

  contradict)
    # Strike through old line only; new content goes to review, NOT to vault.
    # vault-writer --mode stale requires --old-content; --content is also required by
    # vault-writer's arg parser even though stale ignores it — pass old_content as the
    # dummy value (harmless: stale mode only reads --old-content, never --content).
    "$WRITER" \
      --vault       "$VAULT" \
      --page        "$PAGE" \
      --section     "$SECTION" \
      --content     "$OLD_CONTENT" \
      --mode        stale \
      --old-content "$OLD_CONTENT" \
      --undo-log    "$UNDO_LOG"

    # New content queued as destructive (contradictions are structurally destructive
    # regardless of candidate_confidence — overview §4)
    "$QUEUE_SCRIPT" append \
      --bucket     "destructive" \
      --title      "$CONTENT" \
      --evidence   "Contradicts existing: '$OLD_CONTENT'. $RATIONALE" \
      --confidence "$CONFIDENCE" \
      --target     "$PAGE#$SECTION"
    ;;

esac
```

- [ ] **Step 4: Make the script executable**

```bash
chmod +x scripts/apply-decision.sh
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
bash tests/test_apply_decision.sh
```

Expected: all six `PASS:` lines, then `All apply-decision.sh tests passed.`

- [ ] **Step 6: Verify back-compat — existing test suites still pass**

```bash
bash tests/test_vault_writer.sh
bash tests/test_queue.sh
```

Both must exit 0 with their existing pass lines intact.

---

## Task 4: Add `--dry-run` to `scripts/vault-writer.sh` (resolves I2)

`vault-writer.sh` is owned by Plan 1 (built). This is the one place Plan 3 touches it. Add `--dry-run` support: when the flag is present, print the intended change and exit 0 without touching any file or the undo log. All existing behaviour (append/replace/stale) is unchanged when `--dry-run` is absent.

---

- [ ] **Step 1: Add `--dry-run` flag parsing to `vault-writer.sh`**

In the arg-parsing `while` loop, add:

```bash
    --dry-run) DRY_RUN=1; shift ;;
```

And initialise `DRY_RUN=0` with the other variables at the top.

- [ ] **Step 2: Insert the dry-run exit after validation, before any file writes**

After all validation (vault dir, page, section, content checks) and before the mutex lock, insert:

```bash
if [ "$DRY_RUN" = "1" ]; then
  echo "vault-writer [dry-run]: mode=$MODE page=$PAGE_PATH section=$SECTION"
  echo "  content:     $CONTENT"
  [ -n "$OLD_CONTENT" ] && echo "  old_content: $OLD_CONTENT"
  exit 0
fi
```

This ensures dry-run prints the intended change, touches nothing (no lock, no file, no undo log, no index update), and exits 0.

- [ ] **Step 3: Verify existing tests still pass**

```bash
bash tests/test_vault_writer.sh
```

Expected: all existing PASS lines, no regressions.

- [ ] **Step 4: Add a dry-run test to `tests/test_vault_writer.sh`**

Append a new test to `tests/test_vault_writer.sh`:

```bash
# --- Test: --dry-run → vault byte-identical after apply ---

DRYRUN_PAGE="$VAULT/wiki/dryrun.md"
cat > "$DRYRUN_PAGE" <<'EOF'
# DryRun

## Notes

- existing line
EOF

BEFORE=$(cat "$DRYRUN_PAGE")

"$WRITER" \
  --vault    "$VAULT" \
  --page     "wiki/dryrun.md" \
  --section  "Notes" \
  --content  "this must not appear" \
  --mode     append \
  --undo-log "$UNDO_LOG" \
  --dry-run

AFTER=$(cat "$DRYRUN_PAGE")
[ "$BEFORE" = "$AFTER" ] || fail "--dry-run: vault page was modified"
grep -q "this must not appear" "$DRYRUN_PAGE" \
  && fail "--dry-run: sentinel content found in vault"
echo "PASS: vault-writer --dry-run → page byte-identical"
```

Expected: the new PASS line appears alongside all existing ones.

---

## Self-Review

### Spec coverage

| Spec requirement | Covered |
|-----------------|---------|
| `## Reconciliation` section in SKILL.md with prompt logic | Task 1 |
| SKILL.md nested path + guard (`[ -f … ] \|\| exit`) | Task 1, Step 1 |
| Input: `{ candidate, target_page, run_date }` — orchestrator supplies `target_page` + `run_date` (§5) | Task 1, prompt intro + design principles |
| Candidate uses `suggested_section` (not `section`); `source_date` REQUIRED | Task 1, design principles |
| Four action definitions (new/duplicate/supersede/contradict) | Task 1, SKILL.md section |
| Precedence rules (recent user fact > older vault, newer date wins) | Task 1, "Precedence rules" subsection |
| Volatility-driven behaviour (VOLATILE hunts stale; STABLE appends) | Task 1, "Volatility guidance" subsection |
| Output: `action\|mode\|target\|old_content\|content\|candidate_confidence\|needs_review\|rationale` | Task 1 output schema (v2 §4) |
| `mode ∈ append\|replace\|stale\|none` (none for duplicate) | Task 1 output schema + action table |
| `candidate_confidence` required pass-through in output | Task 1 output schema + all fixtures |
| `needs_review` rule: true except `new` + `candidate_confidence:high` | Task 1 output schema notes + action table |
| Golden fixtures: all four actions + `candidate_confidence` in every expected_decision | Task 2 |
| `old_content` present in supersede and contradict fixtures | Task 2, fixtures steps 4–5 |
| `apply-decision.sh` deterministic dispatcher — SOLE owner of action→mode mapping | Task 3 |
| Bucket derived from `candidate_confidence`, not hardcoded | Task 3 (`bucket_for_new` function + contradict always `destructive`) |
| `contradict` → `destructive` queue bucket (not `uncertain`) | Task 3 dispatch table + script |
| M1 stale `--content` wart: one-line comment explaining dummy value | Task 3 `contradict` branch |
| `--dry-run` in `apply-decision.sh`: skip vault writes AND queue writes, exit 0 | Task 3 script |
| `--dry-run` in `vault-writer.sh`: print intended change, touch nothing, exit 0 | Task 4 |
| Test: mock vault byte-identical after dry-run apply | Task 3 Test 6 + Task 4 Step 4 |
| Unit tests for apply-decision.sh (all four actions + bucket assertions) | Task 3, tests 1–6 |
| Existing tests unchanged (back-compat) | Task 3 step 6 + Task 4 step 3 |

### Placeholder scan

No TBD, TODO, or FIXME. All code blocks are complete and runnable. All fixture JSON is valid (validated in Task 1 step 2's verification command).

### Contract consistency

- **Field names**: `action`, `mode`, `target.vault/page/section`, `old_content`, `content`, `candidate_confidence`, `needs_review`, `rationale` are used identically in the SKILL.md output schema (v2 §4), all five fixtures, and the `apply-decision.sh` jq parsing lines.
- **`mode` values**: output schema uses `append|replace|stale|none` (v2 §4). `apply-decision.sh` maps these to actual `vault-writer --mode` calls: `append`→`--mode append`, `replace`→`--mode replace`, `stale`→`--mode stale`. `none` (duplicate) never calls vault-writer. Enum matches v2 §4 exactly.
- **`needs_review:true` → `queue.sh`**: every path where `needs_review` is true lands in a `queue.sh append` call in `apply-decision.sh`. Cross-plan invariant #3 satisfied.
- **`candidate_confidence` drives bucketing**: `apply-decision.sh` reads `candidate_confidence` from the decision JSON via jq; `bucket_for_new()` maps `low→brainstormed`, `medium→uncertain`; `supersede` and `contradict` are always `destructive` (v2 §4). No bucket is hardcoded.
- **`old_content` required for replace/stale**: validated by vault-writer.sh (`--mode replace|stale requires --old-content`); also validated by the model prompt ("omit key for 'new' and 'duplicate'").
- **`contradict` does not write new content to vault**: confirmed in Task 3 script (only `--mode stale` on old line) and enforced by Test 4. New content goes to `destructive` queue bucket.
- **M1 stale `--content` wart**: `apply-decision.sh` passes `--content "$OLD_CONTENT"` for the `contradict` branch. A one-line comment in the script explains why (vault-writer's arg parser requires `--content` even for stale mode, which ignores it). This is harmless and intentional — do not "fix" it.
- **`--dry-run`**: `apply-decision.sh` accepts `--dry-run` and exits 0 before any vault or queue writes; threads `--dry-run` to vault-writer (Task 4). Tested mechanically in Test 6 (byte-identity assertion).

### `apply-decision.sh` include decision

**Included.** Rationale: the JSON→vault-writer flag mapping is deterministic (four fixed branches, fixed flag combos) and therefore fully unit-testable. Without this script, the mapping lives in SKILL.md prose and cannot be tested. The script is also the single dispatch point that future interface changes (e.g. vault-writer gaining new flags) need to touch. The boundary is clean: LLM produces JSON → `apply-decision.sh` translates to shell calls. This is the same architecture used in the existing queue.sh + vault-writer.sh boundary. Cost: ~90 lines of shell + 6 tests. Benefit: testability + isolation. Justified.

---

## Open questions / contract notes

1. **`new` + `needs_review:true` write semantics**: The plan specifies "queue only, do NOT write" for `new/needs_review:true`. The decision JSON still carries `mode: "append"` to be schema-valid, but `apply-decision.sh` checks `needs_review` first and suppresses the write. This is explicit in Test 5. If Plan 4 prefers to always write `new/high-conf` immediately and queue nothing, the single change is removing the `if [ "$NEEDS_REVIEW" = "true" ]` branch from `apply-decision.sh`. No schema changes required.

2. **`--writer` and `--queue` override flags** in `apply-decision.sh`: included for testability (tests can inject mock scripts). Plan 4's orchestrator should use defaults (scripts live in the same directory).

3. **Empty `target_page`**: the prompt instructs the model to treat an empty or missing page as "all candidates are `new`". `apply-decision.sh` does not special-case this — it trusts the decision JSON. Plan 4's orchestrator should ensure the page content passed to the reconciliation step is at least an empty string (per overview §5), not a missing key.

4. ~~**`brainstormed` vs `uncertain` bucket for `new/needs_review:true`**~~ — RESOLVED (v2 I3): `candidate_confidence` is now a required field in the reconciliation-decision output; `apply-decision.sh` derives the bucket from it.

5. ~~**`stale` mode `--content` wart**~~ — RESOLVED (v2 M1): confirmed harmless; `apply-decision.sh` passes `old_content` as the dummy `--content` for vault-writer's arg parser, with an explanatory comment in the script.
