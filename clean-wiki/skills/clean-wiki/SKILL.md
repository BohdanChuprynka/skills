---
name: clean-wiki
description: Monthly Obsidian vault cleanup for Claude Code and Codex. The agent scans selected vaults for stale facts, contradictions, broken wikilinks, index drift, orphans, and frontmatter drift; opens a local swipe-review UI; then applies only user-approved changes with an undo log. Use only when the user explicitly says "/clean-wiki", "$clean-wiki", "clean my wiki", "audit my vault", "tidy my Obsidian", or "run clean-wiki".
---

# clean-wiki

Monthly Obsidian cleanup. **The agent scans and applies. The user makes decisions in the browser.**

## Runtime surfaces

- Claude Code: invoke as `/clean-wiki`; use Claude sub-agents when available.
- Codex: invoke explicitly with `$clean-wiki` or select the skill; use Codex subagent tooling when available.
- If no subagent tool is exposed, scan selected vaults sequentially and tell the user that the scan will be slower.
- Undo is agent-orchestrated: Claude users ask `/clean-wiki --undo`; Codex users ask `Use $clean-wiki --undo`.

## The contract

| Side | Owns |
|--|--|
| **Agent (this skill)** | Asks which vaults, dispatches or runs scans, merges findings, opens swipe UI, applies approved changes after user finishes, writes undo log, writes a per-run clean report. |
| **User (in browser)** | Swipes approve / reject / defer on each finding. Clicks Finish when done. |

## When to invoke

Triggers:
- User explicitly says `/clean-wiki` or `$clean-wiki`
- User explicitly says "clean my wiki", "audit my vault", "tidy my Obsidian", or "run clean-wiki"
- User explicitly asks to run a Clean-Wiki audit

Do **not** auto-trigger. Always user-initiated.

## Orchestration flow

### Step 1 - Resolve the skill directory and ask which vaults

Resolve `skill_dir` before reading or writing any config, queue, decision, or undo files. Check these paths in order and use the first directory containing `clean-wiki.sh`:

1. `./skills/clean-wiki`
2. `.`
3. `${CODEX_HOME:-$HOME/.codex}/skills/clean-wiki`
4. `$HOME/.claude/skills/clean-wiki`

Read `$skill_dir/config/vault-paths.toml` for the configured vaults. Ask the user which vaults to scan. Default selection: the previous run's selection if `$skill_dir/data/preferences.json` exists, else all configured vaults.

In Claude Code, use the available user-question UI if present. In Codex, ask a concise normal question and continue after the user answers.

### Step 2 - Scan selected vaults

Preferred path: dispatch one subagent per selected vault and run them in parallel. Use the active platform's subagent tool; do not pin a platform-specific model in the prompt.

Fallback path: if subagents are not available, scan the selected vaults sequentially in this conversation using the same prompt and output schema.

Scan prompt template, one per vault:

```text
You are auditing a single Obsidian vault for cleanup signals.

VAULT NAME: {vault_name}
VAULT ROOT: {abs_vault_path}
WIKI SUBDIR: {wiki_subdir}

BUILD A TRUTH MODEL FIRST
Before flagging anything, infer the user's current truth by reading:
  - Any page named like Bio / About / Profile / Identity
  - Any page named like Current Priorities / Current Focus / Now
  - Pages with `status: active` in frontmatter
  - Pages with `updated:` in the last 60 days
  - The vault's index.md
This gives you a snapshot of what the user currently considers true.

YOUR JOB
1. Walk every .md file under the vault root.
2. For EACH file, identify cleanup signals:
   - stale_fact:        prose contradicting your truth model, or contradicting another page in this vault
   - broken_wikilink:   [[X]] where X does not exist in this vault (ignore image embeds `![[...]]`)
   - index_drift:       index.md links to a page that does not exist, or misses an obvious active wiki page
   - orphan:            page with 0 inbound links AND not in index.md
   - frontmatter_drift: missing required field (status, updated, tags) on pages that need them
   - stale_superseded:  status: superseded but no link to replacement
   - stale_active:      status: active but updated > 180 days ago

3. SKIP pages with status: archived, superseded, completed, paused.
4. DO NOT flag historical statements clearly labeled as past, code examples, aspirational statements, or subjective opinions.
5. BE CONSERVATIVE. False positives waste user time.

OUTPUT FORMAT
Output ONLY a JSON array. One entry per finding. Each entry MUST have:
{
  "signal": "stale_fact" | "broken_wikilink" | "index_drift" | "orphan" | "frontmatter_drift" | "stale_superseded" | "stale_active",
  "vault": "{vault_name}",
  "target_file": "wiki/path/relative/to/vault/root.md",
  "target_line": <int or null>,
  "snippet": "<verbatim quote from the page, max 300 chars>",
  "why": "<one sentence explaining the issue>",
  "proposed_action": "edit-text" | "delete-line" | "remove-link" | "remove-from-index" | "archive" | "add-replacement-link" | "fix-frontmatter" | "confirm-still-active" | "manual",
  "suggested_replacement": "<replacement text if action is edit-text, else empty>",
  "confidence": "high" | "medium" | "low"
}

If no findings, output [].
NO preamble. NO markdown code fence. JSON array only.
```

### Step 3 - Merge and write `$skill_dir/data/cleanup-queue.json`

Combine all scan outputs. Assign an incrementing `id` like `2026-05-24-001`. Stamp `category` as `"auto"` for `broken_wikilink`/`index_drift`/`frontmatter_drift`, `"judgment"` for everything else. Sort by `confidence` high to low. Preserve deferred or undecided carryover entries from previous runs when present.

Schema:

```json
{
  "generated_at": "ISO8601 UTC",
  "scan_version": "2.0",
  "entries": [
    {
      "id": "2026-05-24-001",
      "signal": "...",
      "signal_label": "human readable",
      "confidence": "high",
      "category": "judgment",
      "vault": "me",
      "target_file": "wiki/...",
      "target_line": null,
      "proposed_action": "...",
      "action_payload": { "source_file": "...", "snippet": "...", "suggested_replacement": "..." },
      "diff": { "verb": "...", "before": "...", "after": "...", "note": "..." },
      "context": "snippet text",
      "deferred_count": 0,
      "first_seen": "2026-05-24",
      "flagged_by": "subagent:me",
      "decided": false,
      "decision": null,
      "decided_at": null
    }
  ]
}
```

Save vault selection to `$skill_dir/data/preferences.json` for next run's default.

### Step 4 - Launch the review UI

Locate the skill directory once in Step 1. Use the already resolved `skill_dir` when launching the UI:

1. `./skills/clean-wiki/clean-wiki.sh`
2. `./clean-wiki.sh`
3. `${CODEX_HOME:-$HOME/.codex}/skills/clean-wiki/clean-wiki.sh`
4. `$HOME/.claude/skills/clean-wiki/clean-wiki.sh`

```bash
bash "$skill_dir/clean-wiki.sh"
```

The server starts on the configured port, default `5173`, and auto-opens the browser to the swipe view. The opened URL carries a one-time `?token=...` that gates the review API, so the user must use the auto-opened tab. Tell the user how many findings are queued.

### Step 5 - Wait for the user to finish

The user swipes through cards. When done, they click **Finish** in the UI, which calls `/api/shutdown`; the Flask process exits and the background shell command returns. Block on this. Do not interrupt.

### Step 6 - Apply approved decisions

Read `$skill_dir/data/decisions.json` (id to `"approve"` | `"reject"` | `"defer"`) and `$skill_dir/data/cleanup-queue.json`. For each entry where decision is `"approve"`:

1. Read the target file.
2. Apply the approved change using normal file edits for text changes and `mv` for archive moves.
3. Before each change, capture the file's prior content for undo.
4. Append to `$skill_dir/data/undo-log.jsonl` one record:

```json
{"batch_id": "20260524T...Z", "ts": "ISO8601", "entry_id": "2026-05-24-001",
 "action": "edit-text", "target_file": "abs/path", "before_content": "...full file before..."}
```

After applying, archive the queue, decisions, scan outputs, and an `apply-summary.json` to `$skill_dir/data/applied/<batch_id>/`.

### Step 6b - Write clean report

Write a dream-style Markdown report for each completed apply batch. Use the bundled helper so report paths and index updates stay deterministic:

```bash
python3 "$skill_dir/scripts/write_report.py" \
  --applied-dir "$skill_dir/data/applied/<batch_id>" \
  --config "$skill_dir/config/vault-paths.toml"
```

The helper writes:

- `<reports_dir>/<YYYY-MM-DD-HHMMSS>.md` — full run report; includes the batch time so multiple runs on the same day never overwrite each other
- `<reports_dir>/index.md` — idempotent one-line run index

`reports_dir` is read from `config/vault-paths.toml` when present. If it is absent, the helper defaults to `clean-reports/` beside the configured vault roots, e.g. the same Obsidian root that contains `me/`, `projects/`, and `dream-reports/`.

### Step 7 - Report

Print to user:
- N changes applied
- M failures with reasons
- Deferred count
- Report path
- Undo request: `/clean-wiki --undo` in Claude Code or `Use $clean-wiki --undo` in Codex

### Step 8 - Stop

Do not approve/reject anything yourself. Do not modify pages beyond what the user approved.

## Undo flow

When asked to undo, read the most recent unapplied batch from `$skill_dir/data/undo-log.jsonl`, restore each file from `before_content`, and stamp the batch as undone. No git is required.

## Safety properties

- Scans are read-only. Mutations only after user approval in the browser.
- Per-card review. Each finding requires explicit swipe or batch approval.
- Undo log per batch: full file content captured before mutation.
- Vault paths come from `vault-paths.toml`; only touch configured vaults.
- Never permanently delete files. Archive/move only when explicitly approved.

## Sub-commands and prompts

```bash
bash "$skill_dir/clean-wiki.sh"      # launch review server; queue must exist
/clean-wiki                       # Claude Code full flow
/clean-wiki --undo                # Claude Code undo flow
Use $clean-wiki to audit my vaults # Codex full flow
Use $clean-wiki --undo             # Codex undo flow
```

## Configuration

`config/vault-paths.toml` (gitignored real version, template at `vault-paths.example.toml`):

- Per-vault: `path`, `wiki_subdir`, `index_file`, `archive_dir`, `required_frontmatter`
- Reports: optional top-level `reports_dir`; defaults to `clean-reports/` beside the configured vault roots
- UI: `port`, `auto_open_browser`

## Scope

This skill does not:
- Create new content; use sync-phone, sync-wiki, or dream-skill.
- Modify content without explicit user approval per finding.
- Push to GitHub.
- Run unattended on a schedule.

Full design rationale in [DESIGN.md](./DESIGN.md).
