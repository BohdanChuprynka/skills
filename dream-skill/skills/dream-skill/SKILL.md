---
name: dream-skill
description: On-demand batch sync of Claude Code conversations to an Obsidian vault. Use when the user says "/dream-skill", "review dream queue", "process dream queue", "sweep dream queue", or asks to update wiki from a recent conversation. Runs a FIND→MAP→REDUCE→ROUTE→RECONCILE→REVIEW→APPLY→RECEIPT→MARKER pipeline over unprocessed transcripts. Type `/dream-skill --ignore` to mark the current chat private so it is never recorded into the vault (undo with `--unignore`).
version: 0.3.0
---

# dream-skill

> This file is read by the LLM at skill invocation time. It contains no executable code.
> Plans 2 and 3 will append `## Routing` and `## Reconciliation` sections below.

## Invocation modes

| Invocation | Mode |
|---|---|
| `/dream-skill` | On-demand run: opens a terminal review session. Runs FIND → MAP → REDUCE → ROUTE → RECONCILE → REVIEW → APPLY → RECEIPT → MARKER. |
| `/dream-skill --since <YYYY-MM-DD>` | Explicit window start override (passes `--since` to `scripts/find-chats.sh`). |
| `/dream-skill --all` | Full-history backfill (weekly-batched; only after pipeline is trusted). Passes `--all` to `scripts/find-chats.sh`. |
| `/dream-skill --dry-run` | Run the full pipeline but write nothing to the vault. Receipt is printed to stdout only. |
| `/dream-skill --ignore` | Mark THIS chat private — skip on next close. |
| `/dream-skill --unignore` | Undo `--ignore` for this chat. |
| `/dream-skill --help` | Print this table, env vars, state paths, and exit 0. |

---

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
3. Resolve `DREAM_SKILL_HOME` (plugin root). Verify the following scripts are present and executable:
   - `scripts/find-chats.sh`
   - `scripts/write-receipt.sh`
   - `scripts/queue.sh`
   - `scripts/vault-writer.sh`
4. Parse `~/.claude/dream-skill/config.toml` (override via `${DREAM_CONFIG}` for tests) to resolve vault roots and `reports_dir`. Parse vault names from `^\[vaults\.<name>\]`, then `root =` per block; `reports_dir =` at top level. `config.toml` is the ONLY source of vault roots — no fallback to `CLAUDE.md` grep.

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

Each subagent returns a JSON array of candidate facts. Validate the JSON structure using the `validate_candidates` harness (required fields ONLY: `content`, `confidence`, `source_chat`, `source_date`). Any subagent output that is not valid JSON, or is missing any required field, is logged as an extraction error and skipped for this run. Missing optional fields (`type`, `evidence`, `suggested_section`) never cause a candidate to be dropped.

**JSON validation shell harness (unit-tested — see `tests/test_map_harness.sh` and `tests/fixtures/map/`):**

```bash
# validate_candidates — embedded logic used in Step 2 MAP processing.
# Must be sourced or inlined; not a standalone script.
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
   - Confidence promotion is the ONLY action REDUCE takes. It does NOT set `needs_review`, does NOT approve facts.
4. Output: a single deduplicated array of candidate-fact objects, with a `source_chat_count` field added to each fact (integer count of distinct source chats that surfaced it).

### Step 4 — ROUTE

Pass each candidate fact to the routing logic defined in `## Routing` (defined below — appended by Plan 2). The routing step resolves each candidate to a `{vault, page, section}` triple (a routing decision per overview §4). If `## Routing` is not yet present in this file, log a gap and queue all candidates as `uncertain`.

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
  "candidate":   { "...full candidate-fact object including source_date..." },
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

**Review UI per entry:**

```
[N/M] <bucket>: <title>

  Evidence:   "<quote>"
  Target:     <vault-relative-path>
  Confidence: <high|medium|low>

[a]pprove  [e]dit  [s]kip  [d]iscard  [q]uit
```

**Approve (`a`):** Promote to the APPLY list for this run. Call `vault-writer.sh` with resolved args + `--undo-log "$DREAM_UNDO_LOG"`. Call `queue.sh remove` to clear the entry. Append `[APPROVED]` line to `$DREAM_DAILY_LOG`.

**Edit (`e`) — free-form field editor:** Prompt: `What to edit? Comma-separated field:value pairs. Valid fields: title, evidence, target, confidence, bucket.` Parse and validate. Re-show full updated entry. Prompt `[a]pply / [r]e-edit / [d]iscard`. On apply: `queue.sh remove` (original key) + `queue.sh append` (new values). Do NOT auto-approve after edit.

**Skip (`s`):** Leave in queue. Advance.

**Discard (`d`):** Call `queue.sh remove`. Advance. Append `[DISCARDED]` to `$DREAM_DAILY_LOG`.

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

For each fact promoted from REVIEW (approved) or for auto-approved facts (confidence=high, action=new, no conflict), call `apply-decision.sh` with the reconciliation decision:

```bash
"$DREAM_SCRIPTS_DIR/apply-decision.sh" \
  [--dry-run] \
  --decision '<reconciliation_decision_JSON>'
```

`apply-decision.sh` (Plan 3) maps `action` + `mode` to the correct `vault-writer.sh` invocation. The orchestrator passes the decision through unchanged.

On vault-writer non-zero exit: log the error to `$DREAM_ERROR_LOG`; continue to the next fact; do NOT advance the marker.

### Step 8 — RECEIPT

After all APPLY calls for a batch complete, generate the receipt using `scripts/write-receipt.sh`:

```bash
"$DREAM_SCRIPTS_DIR/write-receipt.sh" \
  --run-id    "<run_id>" \
  --win-start "<batch_start_date>" \
  --win-end   "<batch_end_date>" \
  --chats     "<source_chat_count_integer>" \
  --reports-dir "<reports_dir from config>" \
  << 'SUMMARY'
<run_summary_JSON>
SUMMARY
```

The run summary JSON passed on stdin must conform to the schema `write-receipt.sh` expects (overview §8): `{ "facts": [ { "content", "target", "action", "review_status", "old_content" } ] }`.

**If `--dry-run`:** print the receipt to stdout instead of writing to `reports_dir`.

**If receipt write fails:** log to `$DREAM_ERROR_LOG`; still advance the marker (receipt failure is not a vault-integrity issue).

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
2. **`nav-context` block** — the output of `scripts/build-nav-context.sh` (reads `~/.claude/dream-skill/config.toml` by default; override with `--config <toml-path>` for tests). Contains, for each vault: 1-line purpose (from config `description`), `wiki/index.md` entries (up to 40 lines), and a dir-scan listing of pages.
3. **`ROUTING.md`** — the disambiguation + volatility supplement (read from the dream-skill root).

### Routing procedure (follow in order)

**Step R1 — Read ROUTING.md §1 disambiguation rules.** Apply the first matching rule to the candidate fact. Note which rule fired and why.

**Step R2 — Confirm the vault in nav-context.** After picking the vault, scan the nav-context block for that vault's `index` and `pages on disk`. Identify the single most specific page that matches the candidate. The page must exist either in the index entries or the dir scan. If no page exists yet → do NOT invent a path; emit `status: gap`.

**Step R3 — Determine the section.** Use `suggested_section` from the candidate if it matches a heading that exists or would logically exist in the target page. Otherwise, infer from the vault CLAUDE.md's page format (visible in the nav-context purpose line or index entry description).

**Step R4 — Apply confidence calibration from ROUTING.md §4.**

**Step R5 — Check for ambiguity.** If after R1–R4 two or more vault+page pairs remain equally plausible with no disambiguation rule resolving them → emit `status: ambiguous`.

**Step R6 — Check for gap.** If no vault rule matched in R1 and no vault page is a reasonable fit → emit `status: gap`.

**Step R7 — If status is `ambiguous` or `gap`:** append one line to the routing-gaps log in `ROUTING.md` using this format:
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
