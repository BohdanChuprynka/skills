---
name: dream-skill
description: On-demand batch sync of Claude Code conversations to an Obsidian vault. Use when the user says "/dream-skill", "review dream queue", "process dream queue", "sweep dream queue", or asks to update wiki from a recent conversation. Runs a FIND→MAP→REDUCE→ROUTE→RECONCILE→REVIEW→APPLY→RECEIPT→MARKER pipeline over unprocessed transcripts. Type `/dream-skill --ignore` to mark the current chat private so it is never recorded into the vault (undo with `--unignore`).
version: 0.3.1
---

# dream-skill

> This file is read by the LLM at skill invocation time. It contains no executable code.
> Plans 2 and 3 will append `## Routing` and `## Reconciliation` sections below.

## Invocation modes

| Invocation | Mode |
|---|---|
| `/dream-skill` | On-demand run: opens a terminal review session. Runs FIND → MAP → REDUCE → ROUTE → RECONCILE → REVIEW → APPLY → RECEIPT → MARKER. |
| `/dream-skill --since <YYYY-MM-DD>` | Explicit window start override (passes `--since` to `"$DREAM_SCRIPTS_DIR/find-chats.sh"`). |
| `/dream-skill --all` | Full-history backfill (weekly-batched; only after pipeline is trusted). Passes `--all` to `"$DREAM_SCRIPTS_DIR/find-chats.sh"`. |
| `/dream-skill --dry-run` | Run the full pipeline but write nothing to the vault. Receipt is printed to stdout only. |
| `/dream-skill --ignore` | Mark THIS chat private — skip on next close. |
| `/dream-skill --unignore` | Undo `--ignore` for this chat. |
| `/dream-skill --help` | Print this table, env vars, state paths, and exit 0. |

---

## Model policy

Every LLM step in this pipeline runs on **Sonnet** (`model: sonnet` → Sonnet 4.6, `claude-sonnet-4-6`):

- **MAP** (Step 2) — one extraction subagent per chat. Dispatch with `model: sonnet`.
- **ROUTE** (Step 4) and **RECONCILE** (Step 5c) — per-candidate judgments. Run each as a Sonnet subagent (`model: sonnet`); the isolated context per candidate also keeps the orchestrator lean (the original context-overflow failure mode).

These are high-volume, tightly-specified steps (read one chat → emit candidate JSON; emit one routing JSON; emit one reconciliation JSON) that Sonnet handles well. Only the orchestrator that stitches the run together (the FIND / REDUCE / REVIEW / APPLY / RECEIPT / MARKER plumbing) runs on the session model. If you ever need maximum fidelity on the destructive-edit judgment, RECONCILE is the single step worth temporarily pinning back to a stronger model — but the default is Sonnet everywhere.

This is a dispatch-level setting (model + per-candidate isolation): it does not change any data contract, so the deterministic test suites are unaffected.

## HARD RULES — read first, apply always

These rules override anything else in this skill. Violating them silently destroys the user's persona-sync.

### Rule 1 — Persistence target is Obsidian vaults ONLY

The ONLY valid write destinations are:
1. Files **inside vault roots** declared in `$DREAM_CONFIG` (via `vault-writer.sh`)
2. The queue file at `$DREAM_QUEUE_FILE` (via `queue.sh`)
3. The daily log at `$DREAM_DAILY_LOG` (plain append)
4. The undo log at `$DREAM_UNDO_LOG` (managed by `vault-writer.sh`)
5. The error log at `$DREAM_ERROR_LOG` (plain append on failures)
6. The marker file at `${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}/last-run` (Step 9)
7. The receipt file in `reports_dir` (via `scripts/write-receipt.sh`)
8. The routing-gaps log at `${DREAM_HOME:-$HOME/.claude/dream-skill}/routing-gaps.log` (plain append when routing returns `ambiguous`/`gap` — Step 5a / R7)

You MUST NOT write to any of these:
- `~/.claude/projects/*/memory/` — that is Claude Code's per-project auto-memory, a different persistence layer.
- Any path outside the vault roots in `$DREAM_CONFIG`
- Any path not under `$DREAM_HOME` or a configured vault root

### Rule 2 — Use the provided helper scripts, never improvise

Vault writes go through `scripts/vault-writer.sh`.
Queue appends go through `scripts/queue.sh`.
Receipts go through `scripts/write-receipt.sh`.
Apply decisions go through `scripts/apply-decision.sh` (Plan 3).
Never use the `Write`/`Edit` tools directly to mutate vault files.

### Rule 3 — Fail loud (in the log), exit gracefully to the user

If any required env var or script path is missing, append a structured error line to `$DREAM_ERROR_LOG` and stop that step. Do NOT try to find an alternative persistence layer.

### Rule 4 — Dry-run is mechanical

When `--dry-run` is active, pass `--dry-run` through to `apply-decision.sh` and `vault-writer.sh` unchanged. No conditional logic — every APPLY call carries the flag.

---

## State layout (env-var sourced)

| Env var | Default | Purpose |
|---|---|---|
| `DREAM_SCRIPTS_DIR` | (resolved at runtime) | Where vault-writer.sh, queue.sh, apply-decision.sh, write-receipt.sh, find-chats.sh live |
| `DREAM_HOME` | `~/.claude/dream-skill` | Runtime state root |
| `DREAM_CONFIG` | `$DREAM_HOME/config.toml` | Vault roots TOML |
| `DREAM_QUEUE_FILE` | `$DREAM_HOME/queue/pending.md` | Deferred-decision facts |
| `DREAM_DAILY_LOG` | `$DREAM_HOME/log/<YYYY-MM-DD>.md` | Human-readable activity log |
| `DREAM_UNDO_LOG` | `$DREAM_HOME/undo/<YYYY-MM-DD>.jsonl` | Per-write rollback entries |
| `DREAM_ERROR_LOG` | `$DREAM_HOME/error.log` | Append on broken-install failures |
| `DREAM_MARKER_DIR` | `$DREAM_HOME` | Directory containing `last-run` marker file |

## Vault config

`$DREAM_CONFIG` is TOML. Each entry maps a logical vault name to its root directory:

```toml
[vaults.me]
root = "/path/to/me"
description = "Identity, skills, experience, projects, career"

[vaults.projects]
root = "/path/to/projects"
description = "Repos, architecture, goals, gotchas"

reports_dir = "/path/to/me/dream-reports"
```

Each vault root should have a `CLAUDE.md` (vault schema/conventions) and `wiki/index.md` (catalog). `vault-writer.sh` handles index auto-update.

If `$DREAM_CONFIG` doesn't exist or has no vault entries: prompt the user to configure it before proceeding.

---

## Orchestration

The on-demand pipeline runs in the following steps. Each step is described below.

### Step 0 — Pre-flight

1. Check the `--dry-run` flag. If set, no vault writes occur; receipt is printed to stdout only. Thread `--dry-run` to `apply-decision.sh` (Plan 3 makes this mechanical).
2. Check `--ignore` / `--unignore`. If present, update the private-state flag for the current transcript and exit. Do not proceed to FIND.
3. Resolve `DREAM_SCRIPTS_DIR` robustly — works as a marketplace plugin OR a bare `~/.claude/skills` symlink. Run:

```bash
# Resolve the scripts dir robustly — works as a marketplace plugin OR a bare ~/.claude/skills symlink.
SKILL_DIR="<the base directory shown in this skill's invocation header>"
REAL="$(cd -P "$SKILL_DIR" && pwd)"              # follow symlink to the real skill dir
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/find-chats.sh" ]; then
  DREAM_SCRIPTS_DIR="$CLAUDE_PLUGIN_ROOT/scripts"            # plugin install
elif [ -x "$REAL/scripts/find-chats.sh" ]; then
  DREAM_SCRIPTS_DIR="$REAL/scripts"                          # self-contained skill dir
elif [ -x "$REAL/../../scripts/find-chats.sh" ]; then
  DREAM_SCRIPTS_DIR="$(cd -P "$REAL/../.." && pwd)/scripts"  # skills/<name>/ under a plugin root (current layout)
else
  echo "dream-skill: cannot locate scripts dir from $REAL — append to \$DREAM_ERROR_LOG and stop (Rule 3)." >&2
fi
DREAM_SKILL_HOME="$(dirname "$DREAM_SCRIPTS_DIR")"
ROUTING_MD="$DREAM_SKILL_HOME/ROUTING.md"
# Verify all helpers exist + executable; if any missing, fail loud (Rule 3) and stop.
for s in find-chats.sh write-receipt.sh queue.sh vault-writer.sh apply-decision.sh build-nav-context.sh validate-candidates.sh; do
  [ -x "$DREAM_SCRIPTS_DIR/$s" ] || { echo "dream-skill: missing $s in $DREAM_SCRIPTS_DIR" >&2; }
done
```
4. Parse `~/.claude/dream-skill/config.toml` (override via `${DREAM_CONFIG}` for tests) to resolve vault roots and `reports_dir`. Parse vault names from `^\[vaults\.<name>\]`, then `root =` per block; `reports_dir =` at top level. `config.toml` is the ONLY source of vault roots — no fallback to `CLAUDE.md` grep.

### Step 1 — FIND

Run:
```bash
"$DREAM_SCRIPTS_DIR/find-chats.sh" [--since <date>] [--all]
```

Parse stdout into a list of `(batch_start, batch_end, [transcript_paths...])` tuples by consuming `BATCH:<start>:<end>` header lines.

**No-marker prompt:** If `"$DREAM_SCRIPTS_DIR/find-chats.sh"` emits no BATCH header (marker missing and no flag), prompt the user:
> No last-run marker found. Choose a window:
> 1. Last 7 days (default — recommended for first run)
> 2. Since <date> (enter a YYYY-MM-DD date)
> 3. All history (--all; weekly-batched; only after pipeline is trusted)

Then re-invoke `"$DREAM_SCRIPTS_DIR/find-chats.sh"` with the chosen flag.

**Empty result:** If a batch contains zero transcript paths, skip to RECEIPT for that batch (write a receipt noting "0 chats in window") and advance the marker — **unless `--dry-run` is active, in which case the marker is never advanced** (I3).

### Step 2 — MAP

For each batch, dispatch one subagent per transcript path using the Task/Agent tool, **with `model: sonnet`** (see Model policy). Each subagent receives:

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

Each subagent returns a JSON array of candidate facts. Validate the JSON structure using the `validate_candidates` harness (required fields ONLY: `content`, `confidence`, `source_chat`, `source_date`). Any subagent output that is not valid JSON, or is missing any required field, is logged as an extraction error and skipped for this run. Missing optional fields (`type`, `evidence`, `suggested_section`) never cause a candidate to be dropped.

**JSON validation harness — use the helper script (Rule 2), do not re-implement:**

Validation lives in `"$DREAM_SCRIPTS_DIR/validate-candidates.sh"` — the single source of truth (unit-tested via `tests/test_map_harness.sh`, which sources this same script; golden inputs in `tests/fixtures/map/`). It filters a candidate array to items carrying all 4 required fields and errors on non-array input. Run it per subagent output:

```bash
# Validate one subagent's JSON array; VALID is the filtered array, or empty on error.
VALID=$(printf '%s' "$subagent_json" | "$DREAM_SCRIPTS_DIR/validate-candidates.sh") \
  || { echo "MAP: invalid candidate JSON (not an array) — skipping this transcript" >&2; VALID="[]"; }
# Or, if sourced:  source "$DREAM_SCRIPTS_DIR/validate-candidates.sh"; VALID=$(validate_candidates "$subagent_json")
```

It checks ONLY the 4 required fields (`content`, `confidence`, `source_chat`, `source_date`); optional fields (`type`, `evidence`, `suggested_section`) never cause a drop.

### Step 3 — REDUCE

After all MAP subagents complete for a batch, merge their outputs. REDUCE is **structural only** — it deduplicates by exact string match on `(content, suggested_section)` and counts distinct `source_chat` values. It NEVER clears `needs_review`, NEVER auto-approves, and NEVER applies semantic equivalence judgments.

1. Flatten all candidate arrays into a single pool.
2. Deduplicate by exact case-insensitive `(content, suggested_section)` pair. Keep the highest-confidence copy; if equal confidence, keep the one with the most `evidence` text. Carry `source_date` through from the kept copy.
3. For facts where N ≥ 2 distinct `source_chat` values share the exact same `(content, suggested_section)`:
   - `N = 2`: raise confidence label to `medium` if currently `low`.
   - `N ≥ 3`: raise confidence label to `high` if currently below `high`.
   - Confidence promotion is the ONLY action REDUCE takes. It does NOT set `needs_review`, does NOT approve facts.
4. Output: a single deduplicated array of candidate-fact objects, with a `source_chat_count` field added to each fact (integer count of distinct source chats that surfaced it).

### Step 4 — ROUTE

Pass each candidate fact to the routing logic defined in `## Routing` (defined below — appended by Plan 2). Execute the routing prompt as one Sonnet subagent per candidate (`model: sonnet`, see Model policy) so per-candidate nav-context never accumulates in the orchestrator. The routing step resolves each candidate to a `{vault, page, section}` triple (a routing decision per overview §4). If `## Routing` is not yet present in this file, log a gap and queue all candidates as `uncertain`.

### Step 5 — RECONCILE

For each routed candidate, perform the following sub-steps (overview §5):

**Step 5a — Route status check:** If the routing decision has `status != "routed"` (i.e. `ambiguous`, `gap`, or similar), mark `needs_review = true`, append to `${DREAM_HOME:-$HOME/.claude/dream-skill}/routing-gaps.log` with timestamp + fact content, route to the `uncertain` queue bucket, and skip reconciliation for this candidate.

**Step 5b — Resolve target page:** For candidates with `status = "routed"`, resolve the absolute path:
```bash
abs_path="<config[vault].root>/<routing_decision.page>"
```
Read the file at `abs_path` (use empty string `""` if the file does not exist — `vault-writer` will create it on a `new` write).

**Step 5c — RECONCILE prompt:** Pass the following to Plan 3's reconciliation logic (the `## Reconciliation` section, to be appended by Plan 3). Execute it as one Sonnet subagent per candidate (`model: sonnet`, see Model policy):
```json
{
  "candidate":   { "...full candidate-fact object including source_date..." },
  "target_page": "<full markdown text of the routed vault page, or empty string>",
  "run_date":    "<today YYYY-MM-DD>"
}
```
Each candidate receives a reconciliation decision per overview §4: `action`, `mode`, `target`, `old_content`, `content`, `candidate_confidence`, `needs_review`, `rationale`. Field is `rationale` (not `reason`).

**Step 5d — Apply:** Feed the reconciliation decision to `apply-decision.sh` (Plan 3). `apply-decision.sh` owns the action→mode→vault-writer mapping. The orchestrator does NOT re-implement this mapping — it passes the decision through unchanged.

### Step 6 — REVIEW

For all facts where `needs_review = true`, call `"$DREAM_SCRIPTS_DIR/queue.sh" append` with the appropriate bucket:
- `destructive` — D-bucket facts or `replace`/`stale` actions on high-stakes facts.
- `uncertain` — E-bucket facts, ambiguous routing, or confidence < high.
- `brainstormed` — facts that are plausible but not directly evidenced.

Then invoke the existing terminal review flow from `"$DREAM_SCRIPTS_DIR/queue.sh" list` for the user to approve / edit / skip / discard each queued item. Facts approved during review are promoted to the APPLY list; discarded facts are removed from the queue.

**Review UI per entry:**

```
[N/M] <bucket>: <title>

  Evidence:   "<quote>"
  Target:     <vault-relative-path>
  Confidence: <high|medium|low>

[a]pprove  [e]dit  [s]kip  [d]iscard  [q]uit
```

**Approve (`a`):** Promote to the APPLY list for this run. Call `"$DREAM_SCRIPTS_DIR/vault-writer.sh"` with resolved args + `--undo-log "$DREAM_UNDO_LOG"`. Call `"$DREAM_SCRIPTS_DIR/queue.sh" remove` to clear the entry. Append `[APPROVED]` line to `$DREAM_DAILY_LOG`.

**Edit (`e`) — free-form field editor:** Prompt: `What to edit? Comma-separated field:value pairs. Valid fields: title, evidence, target, confidence, bucket.` Parse and validate. Re-show full updated entry. Prompt `[a]pply / [r]e-edit / [d]iscard`. On apply: `"$DREAM_SCRIPTS_DIR/queue.sh" remove` (original key) + `"$DREAM_SCRIPTS_DIR/queue.sh" append` (new values). Do NOT auto-approve after edit.

**Skip (`s`):** Leave in queue. Advance.

**Discard (`d`):** Call `"$DREAM_SCRIPTS_DIR/queue.sh" remove`. Advance. Append `[DISCARDED]` to `$DREAM_DAILY_LOG`.

**Quit (`q`):** Stop walking. Remaining entries stay queued. Jump to RECEIPT.

**Summary at end of REVIEW:**
```
Dream queue review complete.
- Approved: X
- Edited:   Y  (still queued; review again to approve)
- Discarded: Z
- Skipped (still queued): W
```

### Step 7 — APPLY

For each fact promoted from REVIEW (approved) or for auto-approved facts (confidence=high, action=new, no conflict), call `apply-decision.sh` with the reconciliation decision. The orchestrator resolves `target.vault` (a logical name like `me`) to its absolute root via `config.toml` before calling, and collects apply-decision's emitted run-summary fact line(s) from stdout for the Step 8 receipt.

```bash
FACT_JSON=$("$DREAM_SCRIPTS_DIR/apply-decision.sh" \
  [--dry-run] \
  --vault    "<abs root resolved from target.vault via config.toml>" \
  --decision '<path-to-decision-json>' \
  --undo-log "$DREAM_UNDO_LOG")
# $FACT_JSON is one JSON line per action (contradict emits two lines)
```

`apply-decision.sh` (Plan 3) maps `action` + `mode` to the correct `vault-writer.sh` invocation and emits one run-summary fact JSON line to stdout per action (contradict emits two: one written-old, one queued-new). The orchestrator passes the decision through unchanged and accumulates the emitted fact lines for Step 8.

On vault-writer non-zero exit: log the error to `$DREAM_ERROR_LOG`; continue to the next fact; do NOT advance the marker.

### Step 8 — RECEIPT

After all APPLY calls for a batch complete, assemble the run-summary JSON from the fact lines emitted by `apply-decision.sh` in Step 7 (`.facts[]` is the array of run-summary fact objects collected from apply-decision's stdout), then pipe it to `write-receipt.sh`. Pass `DREAM_RUNS_DIR` to supply the reports directory.

```bash
# Build run-summary JSON from accumulated apply-decision stdout fact lines.
# Each line from Step 7's $FACT_JSON captures is one element of .facts[].
RUN_SUMMARY=$(jq -cn \
  --arg run_id        "<run_id>" \
  --arg date          "<batch_end_date>" \
  --arg window_start  "<batch_start_date>" \
  --arg window_end    "<batch_end_date>" \
  --argjson chats_scanned "<number_of_transcript_paths_in_this_batch>" \
  --argjson facts     "<json-array of run-summary fact lines from Step 7>" \
  '{run_id:$run_id, date:$date, window_start:$window_start, window_end:$window_end, chats_scanned:$chats_scanned, facts:$facts}')

printf '%s' "$RUN_SUMMARY" | \
  DREAM_RUNS_DIR="<reports_dir from config>" \
  "$DREAM_SCRIPTS_DIR/write-receipt.sh" [--dry-run]
```

`write-receipt.sh` accepts only `--dry-run` and `--config`; all other metadata is passed via stdin in the run-summary JSON. `.facts[]` is assembled by collecting apply-decision's emitted run-summary fact lines from Step 7.

**If `--dry-run`:** print the receipt to stdout instead of writing to `reports_dir`.

**If receipt write fails:** log to `$DREAM_ERROR_LOG`; still advance the marker (receipt failure is not a vault-integrity issue).

### Step 9 — MARKER advance

Only after a batch's APPLY + RECEIPT completes without fatal error — **and never on a `--dry-run`**:

```bash
# A dry-run is a zero-mutation preview: it must NOT advance the marker, or the next
# real run would silently skip the previewed window (see REVIEW-2026-06-04 I3).
if [ "${DRY_RUN:-0}" = "1" ]; then
  : # dry-run — marker intentionally left unchanged
else
  MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
  mkdir -p "$MARKER_DIR"
  printf '%s\n' "<batch_end_date>" > "$MARKER_DIR/last-run"
fi
```

If `--dry-run` is active, do NOT advance the marker under any circumstance. If the run failed during APPLY (vault-writer exited non-zero), also do NOT advance the marker. The next invocation will re-process the same window; vault-writer's idempotency ensures safe re-runs.

For `--all` (multi-batch) runs, the marker advances after each individual batch, so a mid-run failure leaves the marker at the last successfully completed batch boundary.

### Error handling

- MAP subagent fails (non-zero exit or invalid JSON): log the error, skip that transcript, continue.
- ROUTE returns gap/ambiguous: add to gaps log + review queue; never a silent guess.
- APPLY vault-writer exits non-zero: log + continue to next fact; do NOT advance marker if any write fails.
- Receipt write fails: log to `$DREAM_ERROR_LOG`; still advance marker (receipt failure is not a vault-integrity issue).

---

## Extraction taxonomy

Scan each transcript. For each candidate fact, classify into one of these buckets.

**Meta-session rule (important):** If the transcript is about building/debugging dream-skill itself, do NOT blanket-skip as "recursive." Look for concrete decisions the user made: architecture picks, file paths committed to, technical choices, version bumps, default values changed. Those ARE persona signal about their work and belong in vault. Only skip the literal back-and-forth ("yes", "do it", "looks good") as Bucket B execution-confirmations.

### Bucket A — HIGH CONFIDENCE, ADDITIVE → write candidate

**Default to WRITE, not queue.** Queue is an escape hatch for genuinely ambiguous facts, NOT the default. If you find yourself queuing 5+ facts in one run and writing 0, you are being too cautious — re-classify.

A fact qualifies as Bucket A if ALL of:
- New information about the user OR about a project/topic the user is working on (role, project, deadline, preference, decision, relationship, body/health, learning, schedule, technical choice, architecture pick)
- Vault has no current fact that contradicts it
- The user themselves stated it OR the assistant stated it and the user confirmed (acceptance, "yes", "do it", building on it)
- Stated as fact or decision, not pure hypothesis

**Concrete qualifying examples** (emit these, don't queue):
- User picks a tech stack ("we're using Postgres + Drizzle")
- User commits to a project direction ("v0.2 will ship Haiku as default model")
- User states a date or deadline ("Cycle 4 ends 2026-08-17")
- User defines a workflow ("close session → SessionEnd → headless")
- User makes an architecture call ("use add-only writes + queue for destructive")

### Bucket B — GENERAL-KNOWLEDGE Q&A → drop UNLESS signal-bearing

If the user asked a generic technical question and got a generic answer, **drop** (emit nothing).

BUT if the question itself reveals user signal — out-of-domain question, surprising knowledge gap, change in focus area — route to queue under `brainstormed` as a "user explored X today" note.

### Bucket C — CODE BLOCKS → drop UNLESS conceptual

If the conversation is pure code-paste/edit loop: **drop** (emit nothing).

BUT if surrounding prose discusses a concept, architecture decision, or pattern the user is learning/choosing, summarize the **concept** (not the code) as a candidate fact and re-run through Bucket A logic.

### Bucket D — DESTRUCTIVE EDIT → queue

A fact is destructive if it CONTRADICTS or REPLACES existing vault content. Examples: "I'm no longer doing X" (vault still says they do X), "actually it's Y not Z" (vault has Z).

Emit with `confidence` set appropriately; `suggested_section` pointing to the target page. Flag as bucket D in the `type` field if helpful (e.g. `"type": "destructive"`). The reconciler will detect the contradiction.

### Bucket E — UNCERTAIN or BRAINSTORMED → queue

- Medium/low confidence additive fact → emit with `confidence: "medium"` or `"low"`
- User brainstormed an idea but didn't commit ("maybe I should X", "thinking about Y") → emit with `confidence: "low"` and `type: "belief"` or `type: "observation"`

---

## Private opt-out mode (`--ignore` / `--unignore`)

**Interactive, confirmation-only. Writes nothing to the vault — the skip is enforced at the next FIND step.**

When invoked as `/dream-skill --ignore`:

> This chat is now private. dream-skill will skip it during the next on-demand run — nothing from this conversation will be written to your Obsidian vault. Undo anytime with `/dream-skill --unignore`.

When invoked as `/dream-skill --unignore`:

> This chat is no longer private. dream-skill will include it in the next on-demand run as usual.

**How it works:** typing the command leaves a record in the transcript. At FIND time, `scripts/find-chats.sh` calls `scripts/private-state.sh` per transcript and excludes those marked private. Decision is latest-wins and covers the whole chat.

---

## Cross-references

- `HARVEST.md` — patterns ported from v0.1
- `PLAN.md` — v0.2 build plan
- `PLAN-OVERVIEW-2026-06-03.md` — normative data contracts (§4 candidate-fact, §5 seam, §8 invariants)
- `PLAN-04-orchestrator-2026-06-03.md` — this skill's build plan
- `scripts/find-chats.sh` — transcript enumeration + batch boundary slicing
- `scripts/write-receipt.sh` — per-run receipt rendering
- `scripts/vault-writer.sh` — add-only vault append + idempotent index update
- `scripts/queue.sh` — queue file manager (append + list + dedupe by title+target)
- `scripts/apply-decision.sh` — reconciliation decision → vault-writer mapping (Plan 3)
- `scripts/private-state.sh` — resolves a chat's private (`--ignore`) state from its transcript
- `scripts/apply-undo.sh` — rollback writes
- `tests/test_map_harness.sh` — unit tests for `validate_candidates` harness
- `tests/fixtures/map/` — golden fixtures for MAP extraction (manual eval only, not CI)

<!-- Plans 2 and 3 append ## Routing and ## Reconciliation sections below this line. -->

---

## Routing

> **When to run:** once per candidate fact, after MAP produces a `candidate-fact` JSON object and before the Reconciliation step.

### Inputs

1. **`candidate-fact` JSON** — the object from MAP (fields: `content`, `type`, `confidence`, `evidence`, `source_chat`, `source_date`, `suggested_section`).
2. **`nav-context` block** — the output of `"$DREAM_SCRIPTS_DIR/build-nav-context.sh"` (reads `~/.claude/dream-skill/config.toml` by default; override with `--config <toml-path>` for tests). Contains, for each vault: 1-line purpose (from config `description`), `wiki/index.md` entries (up to 40 lines), and a dir-scan listing of pages.
3. **`ROUTING.md`** — the disambiguation + volatility supplement (read from `$ROUTING_MD`).

### Routing procedure (follow in order)

**Step R1 — Read `$ROUTING_MD` §1 disambiguation rules.** Apply the first matching rule to the candidate fact. Note which rule fired and why.

**Step R2 — Confirm the vault in nav-context.** After picking the vault, scan the nav-context block for that vault's `index` and `pages on disk`. Identify the single most specific page that matches the candidate. The page must exist either in the index entries or the dir scan. If no page exists yet → do NOT invent a path; emit `status: gap`.

**Step R3 — Determine the section.** Use `suggested_section` from the candidate if it matches a heading that exists or would logically exist in the target page. Otherwise, infer from the vault CLAUDE.md's page format (visible in the nav-context purpose line or index entry description).

**Step R4 — Apply confidence calibration from ROUTING.md §4.**

**Step R5 — Check for ambiguity.** If after R1–R4 two or more vault+page pairs remain equally plausible with no disambiguation rule resolving them → emit `status: ambiguous`.

**Step R6 — Check for gap.** If no vault rule matched in R1 and no vault page is a reasonable fit → emit `status: gap`.

**Step R7 — If status is `ambiguous` or `gap`:** append one line to the routing-gaps log at `${DREAM_HOME:-$HOME/.claude/dream-skill}/routing-gaps.log` (NOT into `ROUTING.md` — that file is hand-maintained read-only routing guidance) using this format:
```
- <source_date> | <content truncated to 80 chars> | <reason> | proposed-rule: <optional>
```

### Output format

Emit **one JSON object** and nothing else:

```json
{
  "status": "routed",
  "vault": "<vault-name>",
  "page": "<relative-path-from-vault-root>",
  "section": "<section heading>",
  "routing_confidence": "high | medium | low"
}
```

For `ambiguous` or `gap`, set `vault`, `page`, and `section` to `null`.

### Hard constraints

- Output fields are exactly `status`, `vault`, `page`, `section`, `routing_confidence` — no extras (`canonical_path`, `routing_status`, `needs_review`, etc.).
- `status` values are exactly `"routed"`, `"ambiguous"`, or `"gap"` — no other strings.
- `page` must be a relative path from the vault root. Never an absolute path.
- The page must resolve to a CANONICAL page that exists (per nav-context index or dir scan) or be `null`. Never invent a path.
- For `ambiguous` or `gap`: `vault`, `page`, and `section` are always `null`; append to the routing-gaps log (Step R7).
- `routing_confidence` is one of `"high"`, `"medium"`, or `"low"` — calibrated per ROUTING.md §4.

---

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

| Action       | When to use                                                        | mode    | needs_review |
|--------------|--------------------------------------------------------------------|---------|-------------|
| `new`        | The fact (or one semantically equivalent) is absent from the page | append  | false if confidence=high; true otherwise |
| `duplicate`  | An existing line carries the same meaning (wording may differ)    | none    | false |
| `supersede`  | Same subject+attribute, candidate value is newer/more specific    | replace | true |
| `contradict` | Conflicting claims, winner unclear (no clear date precedence)     | stale   | true |

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

- Emit the reconciliation-decision JSON object and nothing else. No explanation, no markdown fencing.
- Every output object MUST include all required keys: `action`, `mode`, `target`, `content`, `candidate_confidence`, `needs_review`, `rationale`.
- `old_content` is REQUIRED for `supersede` and `contradict`; OMIT the key entirely for `new` and `duplicate`.
- `content` for `duplicate` MUST be `""` (empty string), not omitted.
- `target.vault` comes from the routing decision passed in by the orchestrator.
- `target.page` and `target.section` come from the routing decision; do not re-derive them.
- `candidate_confidence` is a verbatim copy of `candidate.confidence` — never change it.
