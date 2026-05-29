# Dream-report vault progress log — design

**Date:** 2026-05-29
**Status:** approved (pending spec review)
**Author:** dream-skill brainstorm

## Problem

The headless auto path (`SessionEnd` hook → `trigger.sh` → `claude -p '/dream-skill --auto'` → `SKILL.md`) writes to three places today:

1. Vault wiki pages (real persona facts) via `vault-writer.sh`
2. The queue (`$DREAM_QUEUE_FILE`) for deferred facts
3. A human-readable daily log at `$DREAM_DAILY_LOG` (`~/.claude/dream-skill/log/<date>.md`)

None of these is visible inside Obsidian. The user cannot glance at the vault and confirm the skill ran, what it captured, or why a given session produced nothing. The legacy `dream-reports/*.md` files (newest `2026-05-26`) came from an older direct-reconcile mode and are no longer produced.

## Goal

Add a vault-visible, append-only progress log so the user can open Obsidian and see, per run: that it ran, when, against which chat, and what happened (wrote / nothing-new / skipped, always with a reason).

**Success criterion:** every real session close produces exactly one vault entry. (The non-events excluded below — `duplicate-dispatch`, `reason=clear`, `no-path-provided` — are not session closes and stay in `~/.claude` only.) An empty day in the vault report means something is broken, not "quiet."

## Non-goals

- Replacing or changing the `~/.claude/dream-skill/` logs. Those stay exactly as-is; they remain the debug/failure channel (`trigger.log`, `error.log`, `headless.log`, daily log).
- Hard failures (didn't start, crashed) producing rich vault output. The vault gets a one-line pointer at most; full detail stays in `error.log`.
- Reconciliation-report content (channels/evidence/confidence). This is an activity log, not the legacy reconcile report.

## Division of responsibility

| Channel | Purpose | Audience | Location |
|---|---|---|---|
| `~/.claude/dream-skill/*` logs | Debugging, failures, ops ledger | Maintainer, debugging | hidden |
| Vault `dream-reports/dream-<date>.md` | Happy-path progress / heartbeat | User, in Obsidian | vault |

The success content is intentionally duplicated (daily log + vault report). Rationale: keep `~/.claude` untouched for debugging, and only *add* a call to `trigger.sh`/`SKILL.md` rather than rewrite existing logic.

## Components

### New: `scripts/report.sh`

The single owner of the vault report format. Both callers go through it so the format lives in one place.

**Interface:**
```
report.sh --status <wrote|noop|skipped|error> \
          --chat   "<label>" \
          [--reason "<text>"] \
          [--time  "<HH:MM TZ>"]      # default: now (local)
          [--reports-dir <dir>]       # default: $DREAM_REPORTS_DIR
# stdin (optional): body lines, used when --status wrote
```

**Behavior:**
1. Resolve reports dir: `--reports-dir` → `$DREAM_REPORTS_DIR` → config `reports_dir` → derived `<Obsidian root>/dream-reports`, where *Obsidian root* is the common parent of the configured vault roots.
2. Resolve day file: `<reports-dir>/dream-<local-YYYY-MM-DD>.md`. Local date and local time are used (user-facing, read in Obsidian).
3. If the file does not exist, create it with frontmatter + H1:
   ```markdown
   ---
   type: dream-activity-log
   date: <YYYY-MM-DD>
   ---

   # Dream activity — <YYYY-MM-DD>
   ```
4. Build the entry as a single string, then append it under a short `mkdir`-based lock (same pattern as `trigger.sh`'s `.locks`) at `<reports-dir>/.report.lock`. Entries are well under `PIPE_BUF` (4 KB), so the append is atomic even if the lock cannot be acquired; the lock is belt-and-suspenders against burst interleaving.
5. **Best-effort, never fatal:** always `exit 0`. On any failure (missing required arg, unwritable reports dir) append a one-line note to `$DREAM_ERROR_LOG` and exit 0. `report.sh` must never break `trigger.sh`'s fire-and-forget contract or the skill.

**Entry formats:**

`--status wrote` (header count = number of `[WRITE]` lines on stdin):
```markdown
### 14:44 EDT — wrote 2
chat: a5a6c577 (Obsidian)
contents:
- [WRITE] projects/project_skills_monorepo.md: dream-skill v0.2 scope
- [WRITE] projects/project_12wy_cycle_4.md: agency thesis direction
- [DROP] preprocess.sh walkthrough (impl detail)
```

`--status noop`:
```markdown
### 17:15 EDT — ran, 0 writes
chat: dream-skill self-ref
reason: recursive-meta (no persona signal)
```

`--status skipped`:
```markdown
### 16:13 EDT — skipped
chat: 68b3c88e (Obsidian)
reason: below-threshold (0 user messages)
```

`--status error`:
```markdown
### 18:02 EDT — error
chat: b419e5e6 (Obsidian)
reason: see ~/.claude/dream-skill/error.log
```

### Modified: `trigger.sh`

- Resolve `DREAM_REPORTS_DIR` (env → config `reports_dir` → derived) and a chat label `DREAM_CHAT_LABEL` ("<first-8-of-uuid> (<basename of cwd>)") early, and export both so the spawned skill inherits them. The chat label uses the cwd basename from the SessionEnd stdin JSON (clean project name, e.g. `Obsidian`, `Persona-RAG`).
- Resolve the path to `report.sh` near the top (before the skip branches), since the skip branches occur before the current `SCRIPTS_DIR` resolution block.
- Call `report.sh --status skipped` at the layer-1 skip branches we want visible:
  - below-threshold (`reason: below-threshold (N user messages)`)
  - unresolved file-not-found (`reason: no transcript found`)
- **Excluded** (ops noise, stay in `trigger.log` only): `duplicate-dispatch`, `reason=clear`, `no-path-provided`. These are not real session closes.
- On successful DISPATCH, `trigger.sh` writes nothing to the vault; the spawned skill writes the run-outcome entry.

### Modified: `SKILL.md` (auto path)

- Add a single `report.sh` call as part of the final action (alongside the existing Step 6 `trigger.log` `COMPLETED`/`ERROR` marker), on **every** exit branch:
  - normal completion → `--status wrote` with the `[WRITE]`/`[QUEUE]`/`[DROP]` lines on stdin (the same lines it already composes for the daily log), or `--status noop` if zero writes/queues with the existing reason enum (`recursive-meta`, `no-info-gain`, `empty-transcript`).
  - internal error → `--status error --reason "see error.log"`.
- Existing daily-log (Step 5) and `trigger.log` (Step 6) writes are unchanged.

### Modified: `config.toml`

- New top-level key `reports_dir = "/Users/bohdan/Documents/IT-Work/Projects/IT/Obsidian/dream-reports"`. `dream-reports/` is a **sibling folder of the persona vaults** under the Obsidian root, so it appears in the Obsidian sidebar next to `me`, `gym-sprint`, `work`, etc. It is deliberately **not** a `[vaults.*]` entry: reconcile must never treat it as a persona vault to read schema from or propose wiki writes to. If the key is absent, callers derive `<Obsidian root>/dream-reports` (the common parent of the configured vault roots).

## Data flow

```
SessionEnd ──> trigger.sh
                 ├─ layer-1 skip (below-threshold | no transcript)
                 │     └─> report.sh --status skipped --reason ...   ──> vault entry  [DONE]
                 └─ pass ──> claude -p '/dream-skill --auto'
                                └─ SKILL.md end:
                                     report.sh --status wrote|noop|error ──> vault entry  [DONE]
```

One entry per invocation, always carrying a reason.

## Error handling and concurrency

- `report.sh` is best-effort: always exits 0, failures noted in `$DREAM_ERROR_LOG`.
- Burst-safe: single-string append under a `mkdir`-lock; atomic small-write fallback if the lock is contended.
- A broken vault write never affects the persona-fact writes, the queue, or the `~/.claude` logs.

## Testing

**New `tests/test_report.sh`:**
- Fresh reports dir → first call creates file with frontmatter + H1.
- Each `--status` value produces the documented entry shape (assert header line, `chat:`, `reason:`/`contents:`).
- `--status wrote` header count equals the number of `[WRITE]` lines piped on stdin.
- Two concurrent calls → both entries present and intact (no interleaving).
- Unwritable reports dir → exit 0, note appended to a temp `DREAM_ERROR_LOG`, no crash.

**Extend `tests/test_trigger.sh`:**
- below-threshold skip → assert a `skipped` entry is written to a temp `DREAM_REPORTS_DIR`.
- unresolved file-not-found → assert a `skipped` entry.
- successful dispatch (stub) → assert `trigger.sh` writes **no** vault entry (the skill owns that).

`SKILL.md` is prompt instructions (not unit-testable); its contract is covered by `report.sh`'s tests plus a manual real-LLM check.

## Implementation coordination

`trigger.sh` and `SKILL.md` are being edited by a second concurrent Claude Code session. The dedicated-`report.sh` design keeps edits to those two files to a single added call each. Implementation should confirm the other session is parked on those files (or coordinate timing) before editing them, to avoid clobbering. `report.sh`, `test_report.sh`, and this spec are new files with no collision risk.

## Out of scope / future

- Reducing the volume of `recursive-meta` runs at the source (dream-skill processing its own sessions). The report will make this noise visible; trimming it is separate work.
- Pulling a first-user-message snippet into the `chat:` label (deferred; id + project is enough for now).
- Pruning/rotating old `dream-reports/` files.
