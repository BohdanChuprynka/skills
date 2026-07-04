# clean-wiki — Design Document

> **Historical v1 architecture.** This document describes the original design where Python scripts (`scan.py`, `semantic_scan.py`, `apply.py`) did the scanning and applying. That code was removed; the current implementation has Claude Code or Codex orchestrate sub-agents for scanning and apply changes directly. The remaining Python helpers are `serve.py` (thin review server) and `write_report.py` (deterministic per-run report renderer). **See [SKILL.md](./SKILL.md) for the current architecture.** Kept here for the design rationale (signal taxonomy, queue schema, undo log, run reports) which still applies.

**Status:** v1 spec (historical)
**Scope:** Phase 1 (mechanical audit) + Phase 3 (Tinder-swipe review UI) shipping today

## Purpose

Six Obsidian vaults written to by `dream-skill`, `sync-wiki`, `sync-phone`, and manual edits. Nothing trims. Result: wiki entropy — orphaned pages, broken `[[wikilinks]]`, index drift, superseded pages with no replacement link, stale frontmatter on ostensibly active items.

`clean-wiki` is the trim layer. Runs monthly, manually. Never auto-deletes. Proposes changes via a Tinder-swipe local web UI; user approves per-card; apply step writes vault with rollback log.

## Mission constraint

**Never lose information that future-you would want.** Every "delete" is preceded by a swipe-right confirmation. Every applied change is reversible from the rollback log. Default action when uncertain: keep.

## Two-source detection model

Detection signals come from two places:

### Source A — Mechanical audit pass (historical: `scan.py`; now done by Claude sub-agents)

> The `scan.py` / `apply.py` references in this section and the `Auto-detected by`
> column below are v1 (removed). The signal taxonomy itself still applies — Claude
> sub-agents now produce these signals and the `/api/decide` review server (`serve.py`)
> replaces the old `/apply` endpoint. See SKILL.md for the live flow.

Pure-rules signals that need no semantic judgment. Phase 1 covers 8:

| # | Signal | Severity | Action proposed | Auto-detected by |
|--|--|--|--|--|
| 1 | **Orphans** — page has 0 inbound `[[wikilinks]]` AND missing from index.md | medium | archive | scan.py |
| 2 | **Broken wikilinks** — `[[X]]` where target X doesn't exist as a file | high | fix-link or remove-link | scan.py |
| 3 | **Stale superseded** — `status: superseded` but page has no outbound link to a replacement page | medium | add-replacement-link | scan.py |
| 4 | **Stale active** — `status: active` AND frontmatter `updated:` > 180 days | low | confirm-still-active (defer if unsure) | scan.py |
| 5 | **Index → file mismatch** — `index.md` lists page that doesn't exist | high | remove-from-index | scan.py |
| 6 | **File → index mismatch** — file exists but not in index.md (and not in `_archive/` etc.) | medium | add-to-index | scan.py |
| 7 | **Empty pages** — body length < 100 chars | medium | delete | scan.py |
| 8 | **Frontmatter drift** — page missing one or more required fields per vault schema (tags, created, updated) | low | fix-frontmatter (manual) | scan.py |

### Source B — Sync-skill semantic flags (Phase 2, deferred)

When `dream-skill` / `sync-wiki` / `sync-phone` writes to vault, they call a shared `flag_for_cleanup()` API to append a queue entry. Catches semantic staleness (e.g. "you updated X, related page Y has stale claim"). Out of scope for v1 — implement after Phase 1+3 ship and prove value.

## Pipeline (Phase 1 + 3)

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. scan.py                                                       │
│    - reads vaults per config/vault-paths.toml                    │
│    - builds inbound-link graph                                   │
│    - emits data/cleanup-queue.json                               │
│      (no vault writes — pure read)                               │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ 2. serve.py — Flask app at http://localhost:5173                 │
│    - reads cleanup-queue.json                                    │
│    - serves Tinder-card UI (one entry per screen)                │
│    - captures decision per entry → data/decisions.json           │
│    - "Apply all" button at end POSTs to /apply endpoint          │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ 3. apply.py                                                      │
│    - reads decisions.json                                        │
│    - executes approved actions (delete/archive/fix-link/etc.)    │
│    - records before-state to data/apply-log.jsonl                │
│    - prints summary                                              │
└──────────────────────────────────────────────────────────────────┘

  Undo: apply.py --undo  (reverses last batch from apply-log.jsonl)
```

## Queue schema (`cleanup-queue.json`)

```json
{
  "generated_at": "2026-05-23T13:00:00",
  "vault_paths": [
    "/Users/.../Obsidian/me",
    "/Users/.../Obsidian/projects"
  ],
  "scan_version": "1.0",
  "entries": [
    {
      "id": "2026-05-23-001",
      "flagged_by": "scan.py",
      "signal": "broken_wikilink",
      "confidence": "high",
      "severity": "high",
      "vault": "notes",
      "target_file": "wiki/Topic Overview.md",
      "target_line": 42,
      "proposed_action": "fix-link",
      "action_payload": {
        "broken_link": "[[Old Topic Name]]",
        "suggested_targets": ["topics/wiki/renamed-topic.md"],
        "fix_strategy": "rewrite_to_vault_relative"
      },
      "reason": "Wikilink [[Old Topic Name]] resolves to no file in the notes vault. Closest candidate in topics vault. Recommend rewrite or remove.",
      "context_snippet": "...See [[Old Topic Name]] for full plan...",
      "decided": false,
      "decision": null,
      "decided_at": null,
      "deferred_count": 0,
      "first_seen": "2026-05-23"
    },
    {
      "id": "2026-05-23-002",
      "flagged_by": "scan.py",
      "signal": "orphan",
      "confidence": "medium",
      "severity": "medium",
      "vault": "notes",
      "target_file": "wiki/_drafts/early-draft.md",
      "proposed_action": "archive",
      "action_payload": {
        "archive_destination": "wiki/_archive/2026-05-23/early-draft.md"
      },
      "reason": "0 inbound links from any vault. Not present in index.md. Frontmatter updated: 2025-11-04. Likely abandoned draft.",
      "context_snippet": "# Early Draft\n\nRough sketch from a while back...",
      "decided": false,
      "decision": null,
      "decided_at": null,
      "deferred_count": 0,
      "first_seen": "2026-05-23"
    }
  ]
}
```

**Per-entry fields:**
- `id` — stable identifier (date + sequence)
- `signal` — which detection rule fired (one of the 8)
- `confidence` — `high` (mechanical certainty) | `medium` (rule fired but might be false positive) | `low` (exploratory, hidden by default in UI)
- `severity` — `high` (broken state, fix urgent) | `medium` (cleanup) | `low` (nice-to-have)
- `target_file` — vault-relative path
- `proposed_action` — verb (see action vocabulary below)
- `action_payload` — params specific to action
- `reason` — human-readable explanation shown in UI
- `context_snippet` — surrounding text for visual context in UI

## Carryover logic (undecided entries persist across runs)

When `scan.py` runs, it first checks for an existing `data/cleanup-queue.json` from a previous session. For each undecided entry from the prior queue:

1. **Re-validate the signal** — run the original detection rule against current vault state
2. If the signal **still fires** for the same target file:
   - Carry entry forward into new queue
   - Increment `deferred_count` (UI shows badge: "deferred 2×")
   - Preserve original `first_seen` timestamp
3. If the signal **no longer fires** (file was deleted, link was fixed, frontmatter updated, etc.):
   - Drop entry silently — problem already resolved
4. Add new entries detected fresh this scan run

This means user can hit "Finish later" with 80% undecided and not lose work. Next month: undecided items return + any new issues are added. Items with `deferred_count >= 3` get a visual nudge to decide.

## Action vocabulary (Phase 1)

| Action | What it does | Reversible? |
|--|--|--|
| `delete` | Removes file | Yes — rollback log stores full content + path |
| `archive` | Moves file to `<vault>/_archive/YYYY-MM-DD/<original-path>` | Yes — file moves back |
| `fix-link` | Rewrites `[[broken]]` → `[[suggested]]` in source file | Yes — rollback log stores original line |
| `remove-link` | Removes `[[broken]]` wikilink from source file (leaves text) | Yes |
| `add-to-index` | Adds entry to `index.md` under the right category | Yes |
| `remove-from-index` | Removes dead entry from `index.md` | Yes |
| `add-replacement-link` | Adds a "Replaced by [[X]]" note to superseded page | Yes |
| `confirm-still-active` | No-op write; just bumps `updated:` date + adds comment | Yes |

**Deferred to Phase 2 / future:**
- `merge` — too complex for v1 (needs semantic diff)
- `split` — too complex
- `fix-frontmatter` — easy but tedious; for v1, output as suggestion in UI, user edits manually in Obsidian

## UI design (Tinder swipe)

### Stack
- Backend: Flask (~150 lines Python)
- Frontend: single HTML file with inline CSS + JS, no build step, no npm
- Port: `localhost:5173` (default; configurable via `--port`)
- Browser opens automatically via `webbrowser.open()`

### Card layout (one entry per screen)

```
┌─────────────────────────────────────────────────────┐
│ clean-wiki · entry 3 of 27                          │
├─────────────────────────────────────────────────────┤
│ [ORPHAN] [confidence: medium] [vault: me]           │
│                                                     │
│ wiki/_drafts/old-bio.md                             │
│                                                     │
│ ━━━ Reason ━━━                                      │
│ 0 inbound links from any vault.                     │
│ Not present in index.md.                            │
│ Frontmatter updated: 2025-11-04 (>180 days).        │
│ Likely abandoned draft.                             │
│                                                     │
│ ━━━ Proposed action ━━━                             │
│ Archive → wiki/_archive/2026-05-23/old-bio.md       │
│                                                     │
│ ━━━ Context ━━━                                     │
│   # Old Bio                                         │
│   First draft from November 2025...                 │
│                                                     │
├─────────────────────────────────────────────────────┤
│  ← Reject    ↓ Open in Obsidian   ↑ Defer   Approve →│
└─────────────────────────────────────────────────────┘
```

### Interactions

| Input | Action |
|--|--|
| `→` arrow / swipe right | Approve proposed action |
| `←` arrow / swipe left | Reject (skip — keep as-is) |
| `↑` arrow | Defer (mark for next month, stays in queue) |
| `↓` arrow | Open file in Obsidian via `obsidian://open?...` URL |
| `Space` | Toggle action variant (when alternatives exist) |
| `Esc` | Save progress + close (resumable) |

### After all reviewed
- Shows summary: X approved, Y rejected, Z deferred
- "Apply now" button → POSTs to `/apply` endpoint → runs apply.py
- After apply, displays result + rollback command hint

### Resumability
- Decisions written to `data/decisions.json` after each card (incremental save)
- Closing browser mid-review → reopen → resumes from next undecided entry

### "Finish later" — explicit exit at any time

User can stop the review session at any point via a **"Finish later"** button (top-right). Effect:
- All entries reviewed so far stay marked with their decisions (approve/reject/defer)
- All entries NOT yet reviewed stay marked as `undecided`
- Session ends; UI shows a summary of (a) what was approved (with optional immediate apply), (b) what's deferred for next month
- No vault writes until user explicitly clicks "Apply approved now"

### Confidence visibility (all entries shown)

**Every entry is shown in the UI regardless of confidence level.** No hidden entries. Each card displays a colored confidence badge so the user makes the decision per-card:
- 🟢 **high** — mechanical certainty (broken link, frontmatter drift, index mismatch)
- 🟡 **medium** — rule fired but might be false positive (orphan, stale active, empty page)
- ⚪ **low** — exploratory / heuristic — reserved for Phase 2 sync-skill flags

User decides at the card level when to keep going or stop. No global filter.

## Apply pipeline (current agent-orchestrated flow)

For each approved decision:
1. Read current state of target file (full content + frontmatter)
2. Record before-state to `data/apply-log.jsonl` (one line per action)
3. Execute action (delete / move / edit / append)
4. Write after-state log line

Atomic per-action. If one fails, stop and report — earlier successful actions stay applied; user can undo all with `--undo` (reverses the whole batch).

After apply, the active agent archives the batch under `data/applied/<batch_id>/` and calls:

```bash
python3 scripts/write_report.py \
  --applied-dir data/applied/<batch_id> \
  --config config/vault-paths.toml
```

The helper writes a dream-style local receipt:

- `<reports_dir>/<YYYY-MM-DD-HHMMSS>.md` — full summary, applied changes, manual leftovers, no-ops, rejections, defers, failures; includes batch time so same-day runs do not overwrite each other
- `<reports_dir>/index.md` — idempotent one-line per-run index

`reports_dir` is optional config. If absent, the helper writes to `clean-reports/` beside the configured vault roots.

**Rollback log entry:**

```jsonl
{"batch_id": "2026-05-23-001", "action_id": "2026-05-23-002", "action": "archive", "before": {"path": "wiki/_drafts/old-bio.md", "content_sha256": "abc...", "content": "..."}, "after": {"path": "wiki/_archive/2026-05-23/old-bio.md"}, "ts": "2026-05-23T13:14:00"}
```

`apply.py --undo` reads the last batch by `batch_id` and reverses each action in reverse order. Multi-batch undo supported.

## Configuration

`config/vault-paths.toml` (gitignored, real version):

```toml
# Vault roots to scan
[[vaults]]
name = "me"
path = "/Users/you/skills-root/Obsidian/me"
wiki_subdir = "wiki"
index_file = "wiki/index.md"
archive_dir = "wiki/_archive"
required_frontmatter = ["tags", "created", "updated"]

[[vaults]]
name = "projects"
path = "/Users/you/skills-root/Obsidian/projects"
wiki_subdir = "wiki"
index_file = "wiki/index.md"
archive_dir = "wiki/_archive"
required_frontmatter = ["tags", "created", "updated"]

# ... gym-sprint, learning, setup, personal-notes

[scan]
stale_active_days = 180
empty_page_max_chars = 100
ignore_globs = [
  ".obsidian/**",
  "**/_archive/**",
  "**/raw/**"
]

[ui]
port = 5173
auto_open_browser = true
default_confidence_filter = ["high", "medium"]  # low hidden by default
```

`config/vault-paths.example.toml` (committed, sanitized placeholder paths).

## Privacy / `.gitignore`

Critical: this skill processes private vault content. Repo must never leak it.

`/Users/you/skills-root/skills/clean-wiki/.gitignore`:

```gitignore
# clean-wiki runtime — NEVER commit vault content
skills/clean-wiki/data/
skills/clean-wiki/.usage-log.jsonl
skills/clean-wiki/.apply-log.jsonl

# Real config with vault paths — keep local
skills/clean-wiki/config/vault-paths.toml
# (template lives at skills/clean-wiki/config/vault-paths.example.toml)

# Python / OS standard
__pycache__/
*.pyc
.venv/
.DS_Store
*.swp
.direnv/

# Web build artifacts (none for v1 — vanilla HTML/JS)
node_modules/
```

**Pre-commit guardrail:** scan README + docs for accidental absolute vault paths before pushing. Manual check before first push.

## Phase 1+3 MVP scope (today)

Ship today:
- ✅ scan.py with 8 mechanical signals
- ✅ serve.py Flask app + single-file HTML/CSS/JS UI
- ✅ apply.py with rollback log
- ✅ config/vault-paths.toml (real, local) + .example.toml (committed)
- ✅ Keyboard arrow controls (touch swipe deferred)
- ✅ Resumable decisions (incremental save)

Deferred:
- ❌ Phase 2: sync-skill hooks
- ❌ Semantic dedup (embeddings)
- ❌ Mobile UI / touch swipe
- ❌ `setup.sh` interactive wizard (manual config edit for v1)
- ❌ `doctor.sh` health check
- ❌ Merge / split actions
- ❌ Auto-suggest fix-link targets via fuzzy match (v1 just lists candidates from glob match on title)

## Skill invocation

User says `/clean-wiki` or "run wiki cleanup":

1. Claude reads SKILL.md
2. Runs `bash clean-wiki.sh` (which orchestrates scan → serve → apply)
3. Or step-by-step: `python scripts/scan.py`, then `python scripts/serve.py`, then `python scripts/apply.py`

`clean-wiki.sh` is the convenience wrapper. Each Python script can be run independently for debugging.

## File layout (final)

```
/Users/you/skills-root/skills/clean-wiki/
├── .gitignore                                  # privacy guards
├── README.md                                   # public-facing intro
└── skills/clean-wiki/
    ├── SKILL.md                                # Claude Code skill entry
    ├── DESIGN.md                               # this file
    ├── clean-wiki.sh                           # orchestrator
    ├── config/
    │   ├── vault-paths.example.toml            # committed template
    │   └── vault-paths.toml                    # gitignored real
    ├── scripts/
    │   ├── scan.py                             # audit → queue
    │   ├── serve.py                            # Flask UI
    │   └── apply.py                            # apply + rollback
    ├── web/
    │   └── index.html                          # single-page Tinder UI
    ├── data/                                   # gitignored runtime
    │   ├── cleanup-queue.json
    │   ├── decisions.json
    │   └── apply-log.jsonl
    └── tests/                                  # placeholder, defer v1
```

## Open decisions (need user input before code)

1. **Vault list:** scan all 6 vaults by default, or start with `me` + `projects` only for v1 testing? Resolved: all 6, with per-vault enable/disable in config.
2. **Empty page threshold:** 100 chars or 200? Resolved: 100.
3. **Archive vs delete:** for orphans, default proposed action `archive` or `delete`? Resolved: `archive` — user can promote to `delete` per-card.
4. **Confidence filter default:** Resolved: NO filter. All entries shown in UI with visible confidence badge. User decides per-card when to stop via "Finish later" button. Undecided items carry over via [Carryover logic](#carryover-logic-undecided-entries-persist-across-runs).

## Success criteria for v1

- Scan completes in <30 sec on 212 files
- UI renders all queue entries
- Approve / reject / defer flow round-trips cleanly
- Apply executes correctly on at least one of each action type
- Rollback fully reverses an applied batch
- No vault content leaks to git (verified before push)

## Future phases (post-today)

- **Phase 2:** Add `flag_for_cleanup()` shared lib + hooks into dream/sync-wiki/sync-phone
- **Phase 4:** Embedding-based semantic dedup with merge proposals
- **Phase 5:** Touch swipe on mobile (PWA or Tauri)
- **Phase 6:** Auto-run on schedule (monthly cron)
