# dream-skill — Full Review (2026-06-04)

> Adversarial multi-agent review of the on-demand-batch rebuild (branch `feat/dream-skill-on-demand-batch`). 5 dimension-reviewers → every finding independently re-verified by a skeptic. **14 raw → 13 confirmed, 1 refuted.** Severity: **2 critical · 5 important · 6 minor.**

The headline: both criticals are reproduced end-to-end, and **both were masked by the tests** (fixtures injected the field the real producer omits / fixture mtimes drifted with the marker). Green suites did not mean correct behavior.

---

## CRITICAL

### C1 · Receipt run-summary is missing `date` → every receipt written to `null.md`
- **Where:** producer `skills/dream-skill/SKILL.md` Step 8 (line ~301) vs consumer `scripts/write-receipt.sh:38,55,78,83,134,141`.
- **What:** Step 8 builds `{run_id, window_start, window_end, chats_scanned, facts}` — no `date`. `write-receipt.sh` reads `.date` with no fallback and uses it for the filename, frontmatter, H1, and the index wikilink + idempotency grep. Reproduced: receipt lands in `null.md`, `date: null`; a second run overwrites it and the index never accumulates → **the audit trail the whole skill exists for is destroyed.**
- **Masked by:** `tests/test_write_receipt.sh:38` hand-injects `"date":"2026-06-03"`, a key the real producer never emits.
- **Fix:** (a) add `--arg date` + `date:$date` to the Step 8 producer; (b) defensive default in `write-receipt.sh`: `DATE=$(... '.date // .window_end // empty'); [ -n "$DATE" ] || DATE=$(date +%F)`; (c) stop pre-injecting `date` in the fixture so the test would catch this.

### C2 · find-chats.sh parses bare dates to *current time-of-day*, not midnight → silent chat loss
- **Where:** `scripts/find-chats.sh:58` (marker branch) and `:80` (--since branch).
- **What:** BSD/macOS `date -j -f "%Y-%m-%d" "$d" +%s` fills H:M:S from the wall clock, so marker `2026-05-01` → `2026-05-01 08:27:38`. The marker is written as a **bare date** (SKILL.md Step 9:321), so the next run re-parses it at a *different* time-of-day: later-in-day runs **permanently skip** chats in the gap; earlier runs reprocess. A sync tool silently losing conversations in its default path.
- **Masked by:** `make_chat` sets mtimes at "N days ago @ now" and markers at "N days ago" (bare) — both drift by the same wall-clock offset, so no test probes an early-morning boundary chat.
- **Fix:** anchor both branches to midnight — `date -j -f "%Y-%m-%d %H:%M:%S" "$d 00:00:00" +%s` (GNU fallback `date -d "$d 00:00:00" +%s`). Add a boundary test: a chat at `touch -t <date>0001` on the marker day must still be emitted.

---

## IMPORTANT

### I1 · README claims the SessionStart hook is a "N chats since last run" nudge — it isn't
- **Where:** `README.md:75,175` vs `scripts/check-pending.sh`.
- **What:** `check-pending.sh` is a **v0.2 orphan scanner**: it reads the legacy `trigger.log`, scans for `SPAWNED/COMPLETED/ERROR` lines, appends `WARNING kind=orphan`, and "outputs nothing to stdout." It never reads `last-run` and never counts transcripts. On a clean v0.3 install `trigger.log` is never written, so the hook is a **no-op**. README sells a feature that doesn't exist.
- **Fix:** reword README to the truth (legacy silent orphan-scan), **or** replace `check-pending.sh` with a real marker-reading counter and keep the copy. (Chosen: see fix log.)

### I2 · Routing-gaps log has two contradictory locations
- **Where:** `SKILL.md:211` (Step 5a → `~/.claude/dream-skill/routing-gaps.log`) vs `SKILL.md:445,472` (Step R7 → inside `ROUTING.md`) vs `docs/architecture.mmd:39` (`routing-gaps.log`). Also: the standalone file is **not** in SKILL.md's Rule-1 allowed-write list (`:32-39`).
- **What:** No script owns this write (raw LLM append), so a real run picks a location arbitrarily; README Observability points at a "routing-gaps log" that may not be where the user looks.
- **Fix:** canonicalize on the standalone `$DREAM_HOME/routing-gaps.log` (ROUTING.md is a hand-maintained *read* input — don't append machine noise into it). Align Step 5a, Step R7, the hard constraint, the Rule-1 allowlist, `ROUTING.md §5`, README, and the diagram.

### I3 · Dry-run is documented as not advancing the marker, but the instructions advance it
- **Where:** `README.md:128` + `docs/architecture.mmd:42` claim "not advanced"; `SKILL.md` Step 9 (`:314-326`) and the empty-result branch (`:148`) advance unconditionally — the only guard is APPLY *failure*, and a dry-run isn't a failure.
- **What:** A dry-run the docs call a "zero-mutation preview" would advance `last-run` and **silently skip the previewed window** on the next real run — the opposite of "look before you leap." Untested.
- **Fix:** add an explicit dry-run guard to SKILL.md Step 9 **and** the empty-result branch ("if `--dry-run`, never advance the marker"). Then add a marker-non-advance assertion to the integration smoke test (also resolves M2).

### I4 · REDUCE (structural dedup + confidence promotion) has zero coverage
- **Where:** `SKILL.md` Step 3 (`:191-201`); no `tests/fixtures/reduce/`, no `test_reduce*`.
- **What:** REDUCE-laundering a low-confidence fact into an auto-approved write is exactly what invariant I6/§8.7 forbids — and nothing tests it. The plan (`PLAN-OVERVIEW:~1212`) specified a `structural-dedup` golden fixture that was never created. It's the one LLM step with no golden example.
- **Fix:** add `tests/fixtures/reduce/` golden case(s): 3 chats sharing `(content, suggested_section)` → merged, `source_chat_count:3`, confidence promoted, `needs_review` NOT cleared.

### I5 · Dead v0.2 code + tests survive and inflate the green count
- **Where:** `scripts/{trigger.sh,preprocess.sh,preprocess-gate.sh,report.sh}` + `tests/{test_trigger.sh,test_e2e.sh,test_preprocess.sh,test_preprocess_gate.sh,test_report.sh}`.
- **What:** `test_trigger.sh` (the largest test file) asserts SessionEnd dispatch/dedupe — architecture-deleted. `test_e2e.sh` tests the dropped `trigger→preprocess` chain. These pass and inflate "all tests green" while the live REDUCE step has none. (`PLAN-OVERVIEW §7` says drop `trigger.sh`; `REDESIGN §5` says *demote* `preprocess*`, don't delete.)
- **Fix:** delete `trigger.sh` + `test_trigger.sh` + `test_e2e.sh` (explicitly "Drop"); add `tests/run-all.sh` listing only live-pipeline tests; leave `preprocess*`/`report.sh` on disk (demoted) but out of the manifest.

---

## MINOR

| ID | Where | What | Fix |
|----|-------|------|-----|
| M1 | `SKILL.md:299` | `chats_scanned` filled from per-fact `source_chat_count` placeholder → wrong "N chats" count | Reference the batch transcript count instead |
| M2 | `README.md:138` vs `:128` | "(enforced by tests)" reads as covering the marker row; only vault byte-identity is tested | Scope the phrasing + add the marker test (with I3) |
| M3 | `README.md:106` | "`--reconcile` (the v0.3 audit stub)" inside a "Removed in v0.3" note → self-contradiction | "v0.2 audit stub" |
| M4 | `tests/test_map_harness.sh:14-24` | Test re-types `validate_candidates` instead of sourcing it (no shared file) → drift tautology | Extract to `scripts/validate-candidates.sh`, source from both |
| M5 | `tests/test_write_receipt.sh:160-167` | `--dry-run` test only asserts "does not crash"; index-suppression unverified | Assert `[ ! -f index.md ]` + non-empty stdout |
| M6 | `tests/test_undo.sh` | `apply-undo --date` resolution and `.applied-*` rename (re-apply protection) untested | Add two cases |

---

## REFUTED (for the record)

- **apply-undo.sh `grep -Fxv` over-matches identical lines** — *refuted.* The literal code is over-broad, but the claimed trigger (vault-writer creating a cross-section duplicate) can't happen: `vault-writer.sh:120` idempotency is page-wide and no-ops the duplicate. Reproduced as a no-op. (Verifier noted a real-but-separate quirk: a no-op append still logs an undo entry, so undoing a no-op deletes the one pre-existing line — single-line, not the claimed bug. Defensive-coding nit only.)

---

## Resolution — all 13 addressed (2026-06-04)

| ID | Status | What changed |
|----|--------|--------------|
| **C1** | ✅ fixed (TDD) | `write-receipt.sh` derives `DATE` as `.date // .window_end // today` (never `null.md`); SKILL.md Step 8 producer now emits `date`; test fixture de-masked + 2 regression guards (`test_write_receipt.sh` tests 9–10). Red→green confirmed. |
| **C2** | ✅ fixed (TDD) | `find-chats.sh` marker + `--since` branches anchor to midnight (`%Y-%m-%d %H:%M:%S` / `$d 00:00:00`); boundary test added (`test_find_chats.sh` test 9, both branches). Red→green confirmed. |
| **I1** | ✅ fixed | README Install + FAQ reworded — the `SessionStart` hook is described as a silent legacy orphan-scanner / no-op on clean v0.3 (real nudge = follow-up). |
| **I2** | ✅ fixed | Canonicalized routing-gaps to `$DREAM_HOME/routing-gaps.log`: SKILL.md Step 5a + R7, added to Rule-1 allowlist, ROUTING.md §5 repointed, README names the file + state layout lists it. (Diagram already correct.) |
| **I3** | ✅ fixed | SKILL.md Step 9 + empty-result branch now explicitly do NOT advance the marker under `--dry-run`. README/diagram claims are now backed. |
| **I4** | ✅ fixed | `tests/fixtures/reduce/structural-dedup.{input,expected}.json` golden fixture (N≥3→high, N=2→medium, `needs_review` never set). |
| **I5** | ✅ fixed | Deleted `trigger.sh` + `test_trigger.sh` + `test_e2e.sh`; added `tests/run-all.sh` (live-pipeline manifest, 11 suites); `preprocess*`/`report.sh` kept (demoted) but excluded. |
| **M1** | ✅ fixed | SKILL.md Step 8 `chats_scanned` placeholder → batch transcript count. |
| **M2** | ✅ fixed | README "Dry-run guarantee" scoped to vault/queue (tested) + marker note (Step 9 rule). |
| **M3** | ✅ fixed | "`--reconcile` (the v0.3 audit stub)" → "earlier v0.2 audit stub". |
| **M4** | ✅ fixed | Extracted `scripts/validate-candidates.sh` (single source); `test_map_harness.sh` sources it; SKILL.md Step 2 + Step 0 preflight reference it. |
| **M5** | ✅ fixed | `test_write_receipt.sh` test 8 now asserts stdout receipt body + no index/file on `--dry-run`. |
| **M6** | ✅ fixed | `test_undo.sh` tests 2–3 cover `.applied-*` rename / re-apply block + `--date` resolution. |

**Verification:** `tests/run-all.sh` → 11/11 live-pipeline suites green. Criticals fixed test-first (each test confirmed RED against the bug, then GREEN). The REDUCE/routing/reconcile/map golden fixtures remain manual-eval (LLM steps; not CI).

**Follow-ups (not blockers, not done here):** (a) replace the legacy `check-pending.sh` with a real "N chats since last run" nudge (I1); (b) consider reimplementing REDUCE as a deterministic shell helper so the I6 anti-laundering invariant is mechanically enforced, not just fixture-documented; (c) the refuted `grep -Fxv` quirk — undoing a no-op append deletes the one pre-existing line — is defensive-coding hygiene only.
