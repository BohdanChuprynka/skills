# Harvest notes — patterns to reuse from v0.1

> v0.1 was a heavy multi-source (sessions + Notion + Calendar + Gmail) map-reduce
> reconciliation skill. v0.2 strips this down to a per-conversation
> auto-on-close architecture. Some logic from v0.1 is worth porting forward.
>
> Everything below lives in git history before the v0.2 reset commit. To
> recover any pattern: `git log --all -- dream-skill/skills/dream-skill/` and
> `git show <commit>:<path>`.

## 1. Proposal-evidence-confidence schema

**Where:** Old `SKILL.md` Section 5 "Stage 4: Apply (manual)" — "Proposal-evidence-confidence model"

**What:** Every queued change has:
- `title` — short summary
- `evidence` — session quote(s) that triggered it
- `confidence` — `high` / `medium` / `low`
- `action` — frontmatter edit | body update | new page | archival
- `target` — vault path + line range

**Why reuse:** This is exactly the queue entry shape for v0.2's `pending.md`. Don't reinvent.

## 2. Target-file resolution + index.md auto-discovery

**Where:** Old `SKILL.md` — "Target-file resolution" + "Vault index updates"

**What:**
- Resolution order: `--index-file <path>` flag → `DREAM_INDEX_FILE` env → auto-discover `<vault-root>/<subdir>/wiki/index.md` → fallback `<vault-root>/<subdir>/index.md` → skip silently
- Idempotent index append: existing links (markdown `[label](path.md)` OR Obsidian `[[wikilink]]`) cause no-op so curated descriptions don't get clobbered
- Index edits recorded in cycle's rollback file under `index_edits` for `apply_undo.sh <date>` reversal

**Why reuse:** Vault routing logic was the hardest part of v0.1 to get right. Port verbatim.

## 3. count_tokens.py utility

**Where:** Commit `5868fcd feat(dream-skill): add count_tokens.py utility with tiktoken + byte fallback`

**What:** Tiktoken-based token counter with byte-count fallback when tiktoken unavailable.

**Why reuse:** Need for budget gating before headless dispatch. Cheaper than guessing.

## 4. .usage-log.jsonl schema v2

**Where:** Commit `6c5c2ee feat(dream-skill): extend .usage-log.jsonl to schema v2 with per-chunk metrics`

**What:** Per-invocation JSONL log: `{date, model, input_tokens, output_tokens, cost_usd, ...}`

**Why reuse:** Cost tracking is needed in v0.2 (every session close = $). Port schema.

## 5. on_exit() robust trap pattern

**Where:** Commits `b429286` and `b525a4c`

**What:** Replaces brittle `trap ... EXIT` with `on_exit()` function + early-exit handling + `set -u` compatibility. Logs token count on exit.

**Why reuse:** Trigger script needs the same robustness — partial transcript writes, killed processes, etc.

## 6. apply_undo.sh pattern

**Where:** Old `SKILL.md` references `apply_undo.sh <date>`

**What:** Per-cycle rollback script that reads the cycle's rollback file (page edits + index edits) and reverses them.

**Why reuse:** Auto-mode writes to vault without confirmation. NEEDS undo escape hatch. Required for v0.2.

## 7. Sanitized config templates

**Where:** Old `config/*.example.toml`

**What:** Public-safe templates with placeholders; real config gitignored.

**Why reuse:** Pattern repeats in v0.2. Keep the gitignore + example.toml convention.

---

## NOT carrying forward

- **MCP-tier model** (Tier 1 Filesystem, Tier 2 Notion/Calendar, Tier 3 Gmail) — v0.2 reads transcript file directly. No MCP needed.
- **Chunked map-reduce path** — single-conversation scale doesn't need it. count_tokens still useful for guard rails.
- **7d / 30d windows** — v0.2 runs per-session, not rolling-window.
- **Setup wizard (`setup.sh`)** — v0.2 ships sensible defaults + plugin hooks auto-install. Minimal setup.
- **Codex CLI support** — v0.2 v1 is Claude Code only. Add Codex later if needed.
