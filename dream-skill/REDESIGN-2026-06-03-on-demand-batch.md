# dream-skill redesign — on-demand observable batch sync

- **Date:** 2026-06-03
- **Status:** Design — awaiting spec review (do not implement yet)
- **Supersedes:** the per-session SessionEnd auto-mode (v0.2.0)

---

## 1. Problem

The current dream-skill runs an LLM extraction pass **inside a per-session SessionEnd hook**, headless. That single architectural choice causes every pain we have:

- **Fragile** — unset env vars (`DREAM_SCRIPTS_DIR`, `DREAM_LOG`, `DREAM_DAILY_LOG`), killed background processes, hostile cwd. Whole sessions burned on infrastructure.
- **Opaque** — it runs unattended, so there's no clear evidence it worked. *This is the #1 complaint.*
- **Noisy** — per-session extraction has no cross-session context, so most of the engineering went into filtering non-signal (recursive-meta detection, empty-transcript gate, dedup).
- **Untestable** — input is "whatever session just ended, in whatever env." No fixed input → every bug is a Heisenbug.

The **original** dream-skill had the right shape — a manual batch sweep of all chats since last run → update the vault. It died for one solvable reason: a week of transcripts didn't fit in one context ("it got too big"). The per-session hook was a mis-fix: it bought small contexts but paid with fragility, opacity, and loss of cross-session signal.

## 2. Goal

Two **observable, review-gated** operations:

- **UPDATE** — pull new durable facts from recent chats into the vault. *(this redesign)*
- **CLEAN** — strip stale/contradicted facts from the vault. *(already exists: `/clean-wiki`)*

**Top requirement, above automation: a clear, verifiable understanding that it works.** Every design choice below is judged against that.

## 3. Locked decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **On-demand, user-run.** No SessionEnd hook, no locks, no triggers, no headless, no env-var bootstrap. | These existed only to serve per-session auto-mode. Deleting them removes the entire friction list by subtraction. |
| D2 | **Terminal review** (Claude Code native). | The old fact-review web UI was already removed; review lives in Claude Code. Reuse the existing approve/edit/skip flow. Least new surface to debug. |
| D3 | **Output = routed writes + a per-run receipt page.** Facts go to their *correct existing pages*; the "one page" is a run summary (found / written-where / skipped), not a destination. | A single destination page would flatten the 7-vault persona model — the thing the vault exists to do. The receipt *is* the "I can see it worked" artifact. |
| D4 | **Reconciliation = per-fact retrieve-then-judge** against the target page; outcomes route through the existing bucket taxonomy. | String-match can't detect supersession; whole-vault comparison reintroduces the context-overflow problem. |
| D5 | **Routing reuses the existing `CLAUDE.md` + `index.md` layers** (+ a thin disambiguation/volatility supplement); `/clean-wiki` is the global backstop. **No vector index.** | Semantic routing without fragility *and* ~no new navigation code — the layers already exist (verified). An index is standing infrastructure that rots, which is what burned us. |
| D6 | **Map-reduce fan-out** — one subagent per chat (map), 1–2 reducers (merge/dedup/cross-session). | Solves the original context-overflow death; same "subagent per unit" pattern `/clean-wiki` already uses (one per vault). |

## 4. Architecture / flow

```
/dream-skill            (you run it; you watch it run)
  1. FIND     chats since last-run marker (mtime); skip any marked --ignore
                no marker? → prompt {last 7d (default) | since <date> | all history}
                overrides anytime: --since <date> / --all
                first real run = small window to validate; --all backfill once trusted
  2. MAP      one subagent per chat → extract candidate facts in ISOLATION
                (small context each → context overflow cannot recur)
  3. REDUCE   merge + dedup candidates across chats; detect cross-session
                repetition ("seen in 3 chats" → higher confidence)
  4. ROUTE    each candidate → target page(s) via the navigation contract
  5. RECONCILE per fact, read its target page → judge:
                NEW → write · DUPLICATE → drop · SUPERSEDES/CONTRADICTS → queue
  6. REVIEW   terminal approve / edit / skip (destructive items always here)
  7. APPLY    vault-writer writes/edits routed facts; per-batch undo log
  8. RECEIPT  write per-run dated receipt (dream-runs/<date>.md) + append 1 line
                to dream-runs/index.md; advance last-run marker
```

Steps 6–7 reuse existing, tested code. Steps 1–5 + 8 are the new orchestration layer.

## 5. Components — keep / drop / new

**Keep (the engine — already good, ~1,170 lines of tests):**
- `vault-writer.sh` — idempotent writes, index update, JSONL undo log, per-page mutex. **(extend — see New)**
- `queue.sh` + 3-bucket queue schema — dedup by (title, target).
- Extraction bucket taxonomy (additive→write · generic/code→drop · destructive→queue · uncertain→queue).
- Terminal review flow (approve / edit / skip / discard).

**Drop (auto-mode scaffolding only):**
- `trigger.sh`, `hooks/hooks.json` SessionEnd entry, per-transcript locks, env-var bootstrap.
- `check-pending.sh` (SessionStart orphan warnings).
- `preprocess*.sh` — **demote**, do not delete: keep as an *optional* cheap pre-filter for obvious giant tool-dumps. Correctness must NOT depend on it (each map subagent reads the chat and judges signal itself).

**New:**
- **Orchestrator** — the FIND → MAP → REDUCE → ROUTE driver (skill logic; may use the Agent tool or a Workflow).
- **Navigation routing contract** + a one-time bootstrap generator (§6).
- **`vault-writer` edit/replace/mark-stale capability** — currently add-only/append. This is the heart of solving supersession. *The single most important new piece of code.*
- **Receipt writer** — per-run summary page.
- **Last-run marker** — timestamp state; advanced on run completion (not per-fact).

## 6. Navigation routing contract

**Reuse what already exists — do NOT build a navigation system.** Verified 2026-06-03 against the live vaults: the routing "contract" is ~90% already written, across three layers already maintained:

- **Global `~/.claude/CLAUDE.md`** → the *which-vault* decision (vault table + when-to-consult examples already present).
- **Per-vault `CLAUDE.md`** → the *within-vault rules + page schema* ("one page per role/skill/project", page format, `status`/volatility fields, a Lint op). This IS the routing-rules layer, already authored per vault.
- **Per-vault `wiki/index.md`** → the *page catalog*: `[[Page]] — one-line description` (projects/ even carries a Status column). Confirmed rich and descriptive — exactly the "file + sentence" map, already maintained.
- **Structure check**: re-derive the file list from disk on demand (`find`) to catch pages the index hasn't listed yet; peek at frontmatter/H1 only when a name is ambiguous.

The ONLY net-new authored artifact is a thin **disambiguation + volatility supplement** for genuinely cross-cutting cases — appended to the global CLAUDE.md (or a small `ROUTING.md`), not a large new file.

Routing path: read global CLAUDE.md → pick vault → read that vault's CLAUDE.md + `index.md` → pick the **canonical** page. Two-to-three bounded reads, ~1k tokens/decision, constant as the vault grows (vs ~6k and linear for a flat manifest).

**Thin supplement / combined view (illustrative):**
```markdown
# Vault Routing Contract   (router reads this FIRST)
<!-- STRUCTURE: auto-refreshed from disk. RULES: hand-maintained. -->

## Precedence
User's words in the source chat > existing page (newer `updated:` wins) > auto-memory.

## Vaults
### me/ — who Bohdan is
   purpose: identity, skills, experience, education, career, goals
   pages:   (auto-listed from disk)
   volatility: goals/now/* = VOLATILE (supersede-prone) · skills/experience = STABLE (append)
   route when: a durable fact about Bohdan himself
### projects/ · gym-sprint/ · work/ · learning/ · setup/ · personal-notes/ … same shape

## Disambiguation   (cases folder descriptions can't settle)
- "used/learned <tech>" → capability he has → me/skills ; choice inside a repo → projects/<x>/architecture
- a person → client/prospect → work/pipeline ; persona → me
- course insight → learning/ ; subject exam fact → personal-notes/

## Routing-gaps log   (append when a fact won't route cleanly; fold into rules later)
```

**Generation model:** bootstrapped once (LLM walks the tree + reads existing index/CLAUDE.md files → drafts contract → **user reviews**), then self-maintaining (structure auto-refreshed; rules edited rarely; misroutes appended to the gaps log and folded back in → contract gets smarter over time).

## 7. Reconciliation logic (the judge)

Per candidate, after routing to a target page, read that page and classify:

| Class | Action |
|-------|--------|
| **NEW** — not present | append (additive bucket → may auto-write if high confidence) |
| **DUPLICATE** — same meaning, any wording | drop |
| **SUPERSEDES** — same subject, newer value | edit/replace old + bump `updated:` (or set `status: archived`) — **review-gated** |
| **CONTRADICTS** — conflicts, unclear winner | flag, never auto-resolve — **review-gated** |

- **"Outdates" detection:** process chats oldest→newest, carry timestamps; apply precedence (recent user-stated fact > older vault claim). Brainstormed/hypothetical content stays in the uncertain bucket.
- **Volatility-driven:** on a `VOLATILE` page the judge actively hunts for the now-stale version; on `STABLE` it just appends.
- **Any destructive edit (supersede/contradict/delete) is review-gated** — matches the existing "destructive" bucket and the observability priority.

**Canonicalization (observed drift — the real problem).** Inspecting the live indexes on 2026-06-03 revealed variant pages for single topics — e.g. `Relationships.md` / `relationships.md` / `Life-Relationships.md` in me/, and `Aximon.md` / `aximon.md`, `Persona-RAG.md` / `persona-rag.md` in projects/. This is the fingerprint of the old **add-only** writer creating new pages instead of updating canonical ones. Two consequences:
1. **Routing must resolve to the ONE canonical page** for a topic (the index/CLAUDE.md schema defines it); never silently create a casing/spacing variant.
2. **A one-time `/clean-wiki` merge pass** is a prerequisite — fold existing variants together before UPDATE runs at quality. Navigation was never the hard part; canonicalization is.

## 8. Observability requirements (the "I can see it works" contract)

- Visible run progress: per-chat extraction results surfaced as the batch runs.
- The **receipt**: a per-run dated file (`dream-runs/<date>.md`) — found / written-where / superseded / skipped / queued, with `[[wikilinks]]` to touched pages + an undo id — plus a one-line-per-run `dream-runs/index.md` for glanceable history.
- Review gate before any vault mutation.
- **Idempotent re-runs** (vault-writer skips existing) → safe to re-run; builds trust.
- **Dry-run mode**: produce the receipt + proposed edits *without* writing.

## 9. Testing strategy (quality, not v1)

- **Routing tests** — assert `fact X → page Y` against the contract (routing becomes a verified function, not a vibe).
- **Reconciliation tests** — fixtures for duplicate / supersede / contradict / new.
- **vault-writer tests** — extend existing suite for the new edit/replace/mark-stale + idempotency.
- **End-to-end** — fixture transcripts → expected routed edits + receipt.
- **Edge handling** — empty chat skipped; monster chat chunked; `--ignore` honored; marker advances only on completion.

## 10. Edge cases

- **Monster chat** (single session exceeds one subagent's context) → chunk that chat into pieces (sub-map), reduce within the chat first.
- **`--ignore`'d chats** → skipped at FIND (keep a simple skip-list; drop the transcript-regex detection).
- **Ambiguous routing** → gaps log + review, never a silent guess.
- **Failed/partial run** → last-run marker advances only after a completed batch; idempotent writes make re-runs safe.
- **No last-run marker** (first run, or marker lost) → never guess silently. Prompt with **last 7 days as the default** (small, eyeball-able — validate the pipeline before trusting it), plus **since `<date>`** and **all history** (`--all`). The vault is already populated, so an all-history sweep is mostly dedup against existing pages — do the deliberate full backfill via `--all` once the pipeline is trusted, not as the first run.
- **Large window / first-run bootstrap** → process in time-batches (week by week); each batch is its own map→reduce→review→receipt, advancing the marker per batch. Even a full-history sweep stays bounded, resumable, and observable — the original "it got too big" failure stays dead.

## 11. Out of scope (YAGNI)

- Vector/embedding index (D5).
- Web review UI (removed; revisit only if the terminal flow proves insufficient).
- Per-session auto-mode (the thing we're removing).
- **Codex transcripts** — Claude Code only in this build; the FIND step stays source-pluggable so `~/.codex/sessions` drops in later without rework.

## 12. Resolved decisions (2026-06-03)

1. **Sources:** Claude Code only in this build. The FIND step is left source-pluggable; Codex (`~/.codex/sessions`) is a later drop-in, not now.
2. **Receipt:** per-run dated files `dream-runs/<date>.md` + a one-line-per-run `dream-runs/index.md` for glanceable history.
3. **Build order:** (a) one-time `/clean-wiki` canonicalization pass to merge existing drift (e.g. the `Relationships` / `relationships` / `Life-Relationships` variants) → (b) author + review the thin disambiguation/volatility supplement → (c) build the engine (vault-writer edit/replace capability, orchestrator, reconciler, receipt + index).
