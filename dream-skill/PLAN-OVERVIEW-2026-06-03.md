# Plans 2–4 — Shared Contracts & Overview (v2, post-dive-check)

> This is the **single normative source** for all cross-plan contracts. Plans 2, 3, 4 must quote these schemas/paths VERBATIM. If a plan disagrees with this file, this file wins. v2 resolves the dive-check blockers (see §9).

## 1. Pipeline (who owns what)

```
/dream-skill  (orchestrator = Plan 4)
  FIND      chats since marker        → Plan 4  (find-chats.sh)
  MAP       subagent per chat         → Plan 4 dispatches; reuses existing extraction taxonomy; emits candidate-fact JSON (§4)
  REDUCE    merge/dedup (structural)  → Plan 4 (§4 REDUCE rule)
  ROUTE     candidate → canonical page→ Plan 2  (build-nav-context.sh + routing prompt + ROUTING.md)
  READ PAGE resolve abs path, read it → Plan 4 (§5 seam) — supplies target_page to RECONCILE
  RECONCILE candidate+page → decision → Plan 3  (reconciliation prompt → apply-decision.sh)
  REVIEW    approve/edit/skip         → Plan 4 reuses queue.sh
  APPLY     write (or dry-run)        → apply-decision.sh → vault-writer.sh (Plan 1)
  RECEIPT   reports_dir/<date>.md+idx → Plan 4 (write-receipt.sh)
  MARKER    advance after batch       → Plan 4
```

## 2. Build order & EXACT paths (resolves I1, B4)

- **Repo (git root):** `/Users/bohdan/Documents/IT-Work/Projects/IT/skills`. Plugin dir: `dream-skill/`. Scripts: `dream-skill/scripts/`. Tests: `dream-skill/tests/`.
- **SKILL.md (EXISTS — modify, do not create):** `dream-skill/skills/dream-skill/SKILL.md` (nested). Scripts are invoked as `${CLAUDE_PLUGIN_ROOT}/scripts/<x>.sh` where plugin root = `dream-skill/`.
- **Config (EXISTS):** `~/.claude/dream-skill/config.toml` — TOML, parsed like `scripts/report.sh` does. Keys: `reports_dir = "<path>"` (where receipts go), and `[vaults.<name>]` blocks with `root = "..."` and `description = "..."`. **6 active vaults** (me, projects, gym-sprint, setup, personal-notes, work); `learning` is commented out / absent — handle its absence gracefully, never require it.
- **Receipts dir:** the config `reports_dir` (currently `…/Obsidian/dream-reports`). Per-run file `<reports_dir>/<YYYY-MM-DD>.md` + one-line append to `<reports_dir>/index.md`. (Do NOT hardcode `dream-runs/`.)
- **Marker:** `~/.claude/dream-skill/last-run`.
- **IMPLEMENTATION ORDER: Plan 4 → Plan 2 → Plan 3.** Plan 4 first restructures SKILL.md (strip auto-mode/SessionEnd sections; add the on-demand orchestration steps that reference `## Routing` and `## Reconciliation` as "defined below") and builds the plumbing scripts. Then Plan 2 appends `## Routing`; Plan 3 appends `## Reconciliation`. Each of Plans 2/3 starts with a guard: `[ -f <SKILL.md> ] || { echo "run Plan 4 first"; exit 1; }`.

## 3. Deterministic vs LLM (decides testing)

- **Deterministic (shell) → unit-tested** (plain-shell harness: `fail()` + `PASS:` echoes, mktemp/env-var roots): `find-chats.sh`, `build-nav-context.sh`, `write-receipt.sh`, `apply-decision.sh`, marker handling, `validate_candidates`, hooks.json edit, vault-writer `--dry-run`.
- **LLM judgment → golden-fixture + documented manual/eval acceptance, NOT model-in-CI**: extraction (MAP), routing decision (Plan 2), reconciliation decision (Plan 3). Specify the exact prompt + `tests/fixtures/<area>/*.json`. The shell that parses/validates the model's JSON IS unit-tested.

## 4. Data contracts (NORMATIVE — quote verbatim; resolves B1, B2, I2, I3)

### Candidate fact — MAP output; flows through the pipeline
Required: `content`, `confidence`, `source_chat`, `source_date`. Optional: `type`, `evidence`, `suggested_section`.
```json
{
  "content": "Cleveland Clinic internship confirmed for Jun–Aug 2026",
  "confidence": "high | medium | low",
  "source_chat": "<session-id>",
  "source_date": "2026-06-01",
  "type": "world-fact | belief | observation | experience",
  "evidence": "short quote/paraphrase from the chat",
  "suggested_section": "Experience"
}
```
- `content` → the `- <content>` line. `source_date` is REQUIRED (drives supersession precedence: newer user-stated fact > older vault claim). `suggested_section` is a hint only; the router may override. **`validate_candidates` checks ONLY the 4 required fields** (never drops a fact for missing optionals). `needs_review` is NOT on the candidate — it is set by reconciliation.

### Routing decision — Plan 2 output, per candidate
```json
{ "status": "routed | ambiguous | gap",
  "vault": "me", "page": "wiki/experience.md", "section": "Experience",
  "routing_confidence": "high | medium | low" }
```
- Field is `status` (not `routing_status`). `page` is relative to the vault root; the orchestrator resolves the absolute path from config (§5). `ambiguous`/`gap` → `needs_review` downstream + append to the routing-gaps log; never silently guessed.

### Reconciliation decision — Plan 3 output, per routed candidate (after reading target page)
```json
{ "action": "new | duplicate | supersede | contradict",
  "mode": "append | replace | stale | none",
  "target": { "vault": "me", "page": "wiki/experience.md", "section": "Experience" },
  "old_content": "lives in Berlin",
  "content": "lives in Munich (moved 2026-06)",
  "candidate_confidence": "high | medium | low",
  "needs_review": true,
  "rationale": "newer source_date, same subject → supersede" }
```
- `action` enum is EXACTLY `new|duplicate|supersede|contradict` (never mode-values). `mode` is `append|replace|stale|none` (`none` for duplicate). Field is `rationale` (not `reason`). `candidate_confidence` is a REQUIRED pass-through of the candidate's `confidence` (drives queue bucketing).
- **`needs_review` rule:** `true` for everything EXCEPT `new` + `candidate_confidence:high`. (i.e. all destructive edits, all contradictions, and all low/medium-confidence news go to review.)
- **action → behavior (owned by `apply-decision.sh`):**
  - `new`  → `vault-writer --mode append` if not needs_review; else `queue.sh` (bucket: medium→`uncertain`, low→`brainstormed`).
  - `duplicate` → no write, no queue (drop; counts as "skipped").
  - `supersede` → `vault-writer --mode replace --old-content <old>` (destructive → also queued for review per the rule).
  - `contradict` → `vault-writer --mode stale --old-content <old>` (mark old) **and** `queue.sh` the new fact (`destructive` bucket).

### vault-writer invocation (Plan 1, built) + dry-run (resolves I2)
```
vault-writer.sh --vault <root> --page <rel> --section <sec> --content <new> \
  [--mode replace|stale --old-content <old>] [--dry-run] --undo-log <path>
```
- `--dry-run` (NEW, add in Plan 3): print the intended change, touch nothing, exit 0. `apply-decision.sh` accepts `--dry-run` and threads it to vault-writer (and skips queue writes). The orchestrator passes `--dry-run` whenever the run is a dry run. Test: a mock vault is byte-identical after a dry-run APPLY.

## 5. The route → reconcile → apply seam (resolves B3)

After ROUTE returns a routing decision for a candidate, the **orchestrator (Plan 4)**:
1. If `status != routed` → mark `needs_review`, append to routing-gaps log, route to `uncertain` queue bucket; skip reconcile.
2. Else resolve `abs_path = <config[vault].root>/<page>` and read the file (empty string if it doesn't exist — `vault-writer` will create it on a `new` write).
3. Pass `{ candidate, target_page: <file contents>, run_date: <today> }` to the RECONCILE prompt (Plan 3).
4. Feed the reconciliation decision to `apply-decision.sh`.

## 6. Config parsing (resolves B3/B4, M3)

`build-nav-context.sh` (Plan 2) and the orchestrator (Plan 4) both read `~/.claude/dream-skill/config.toml` (override via `${DREAM_CONFIG}` for tests). Parse like `scripts/report.sh`: vault names from `^\[vaults\.<name>\]`, then `root =` and `description =` per block; `reports_dir =` at top level. **Use the `description` field as each vault's purpose** in the nav-context (do NOT scrape each vault's CLAUDE.md). There is NO `vaults.conf`.

## 7. Reuse (do not reinvent)
- **MAP extraction:** reuse the existing extraction taxonomy already in SKILL.md (A write / B,C drop / D,E queue) — emit the §4 candidate-fact JSON.
- **Review:** `scripts/queue.sh` (buckets: destructive / uncertain / brainstormed; dedup by (title, target)).
- **Apply + undo:** `vault-writer.sh` + `apply-undo.sh`.
- **Drop (per REDESIGN §5):** `trigger.sh`, the **SessionEnd** hook entry in `hooks/hooks.json`, locks, env bootstrap. The **SessionStart**/`check-pending.sh` entry: KEEP but it is harmless on-demand (a "you have N chats since last run" nudge); removing it is optional. Plan 4 MUST remove the SessionEnd entry.

## 8. Cross-plan invariants (the dive-check re-verifies these)
1. The three JSON contracts in §4 are used with IDENTICAL field names/enums across all plans. No plan redefines them.
2. `mode` ∈ {append, replace, stale, none}; the action→mode→vault-writer mapping lives ONLY in `apply-decision.sh`.
3. Every `needs_review:true` path lands in `queue.sh`; queue bucket derives from `candidate_confidence`.
4. Routing resolves to a CANONICAL page; `ambiguous`/`gap` → review + gaps log (never silent).
5. No LLM extraction inside a hook; MAP is subagent-per-chat at run time. Marker advances ONLY after a completed batch.
6. Window default = last 7 days; `--all` = explicit, weekly-batched. A non-parseable marker falls back to 7 days, NEVER to epoch-0/all-history (resolves I4).
7. REDUCE confidence promotion is STRUCTURAL ONLY: count distinct `source_chat` for exact `(content, suggested_section)` matches; semantic equivalence may raise a confidence *label* but MUST NOT clear `needs_review` / auto-approve (resolves I6).
8. Receipt sections derive from the reconciliation `action`: Written = applied `new`(append)+`supersede`(replace); Superseded = lines struck via `stale` (the contradict old-line); Queued = anything with review_status queued (incl. contradict's new fact); Skipped = `duplicate`. The receipt test fixture must make a supersede item and a contradict item DISTINCT (resolves I5/I7).

## 9. Dive-check resolutions (what changed in v2 and why)
- **B1 (candidate-fact schema):** §4 is now the single schema with REQUIRED `source_date` + `suggested_section`; `validate_candidates` checks only required fields; `needs_review` removed from candidate. Plan 4 MAP/fixtures/validate must adopt this.
- **B2 (action/mode):** §4 fixes `action ∈ new|duplicate|supersede|contradict`, `rationale` (not reason); Plan 4 deletes its action/mode table and defers mapping to `apply-decision.sh`.
- **B3 (config + target-page seam):** §6 = config.toml is the source; §5 = orchestrator reads the target page and passes it to reconcile.
- **I1 (SKILL.md/build order):** §2 = nested path, MODIFY existing, order 4→2→3, guards in 2/3.
- **I2 (dry-run):** §4 = mechanical `--dry-run` in vault-writer + apply-decision + orchestrator, with a no-write test.
- **I3 (candidate_confidence):** §4 = required pass-through; queue bucket derives from it.
- **I4 (marker fallback):** §8.6 = non-parseable marker → 7-day fallback.
- **I5/I7 (receipt bucketing):** §8.8 = action-derived sections; fixture must be non-tautological.
- **I6 (REDUCE laundering):** §8.7 = structural promotion only; never auto-clears needs_review.
- **M1 (stale --content wart):** confirmed harmless; `apply-decision.sh` passes old-content as the dummy `--content` and adds a one-line comment.
- **M2/M3 (learning vault / purpose):** 6 vaults; purpose from config `description`; degrade gracefully when a vault lacks CLAUDE.md/index.
