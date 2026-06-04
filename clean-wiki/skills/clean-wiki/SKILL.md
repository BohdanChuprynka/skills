---
name: clean-wiki
description: Monthly Obsidian vault cleanup. Claude scans selected vaults with sub-agents (catches stale facts, contradictions, broken links, drift), then opens a local web UI where the user swipes approve/reject on each finding. After review, Claude applies approved changes directly via Edit, recording an undo log. Use when the user says "/clean-wiki", "clean my wiki", "audit my vault", "tidy my Obsidian", "run clean-wiki", or mentions wiki entropy / stale info / redundant pages.
---

# clean-wiki

Monthly Obsidian cleanup. **Claude does the scanning and applying. The user makes decisions in the browser.**

## The contract

| Side | Owns |
|--|--|
| **Claude (this skill)** | Asks which vaults, dispatches sub-agent per vault, merges findings, opens swipe UI, applies approved changes after user finishes, writes undo log. |
| **User (in browser)** | Swipes approve / reject / defer on each finding. Clicks Finish when done. |

## When to invoke

Triggers:
- User says `/clean-wiki`
- User says "clean my wiki", "audit my vault", "tidy my Obsidian", or similar
- User mentions wiki entropy, redundant pages, "too much info accumulated"

Do **not** auto-trigger. Always user-initiated.

## Orchestration flow (what Claude does)

### Step 1 — Ask which vaults

Read `config/vault-paths.toml` for the list of configured vaults. Present them via AskUserQuestion (multi-select). Default selection: the previous run's selection if `data/preferences.json` exists, else all.

### Step 2 — Dispatch one sub-agent per selected vault (parallel)

For each selected vault, launch a sub-agent with the prompt below. Run them concurrently — separate Agent tool calls in a single message. **Dispatch every scan sub-agent on Sonnet (`model: sonnet`, i.e. Sonnet 4.6 / `claude-sonnet-4-6`).** The audit is high-volume read-and-classify work that Sonnet handles well; the orchestrator (this conversation) still merges findings and applies approved changes on whatever model the session runs.

Sub-agent prompt template (one per vault):

```
You are auditing a single Obsidian vault for cleanup signals.

VAULT NAME: {vault_name}
VAULT ROOT: {abs_vault_path}
WIKI SUBDIR: {wiki_subdir}

BUILD A TRUTH MODEL FIRST
Before flagging anything, infer the user's current truth by reading:
  - Any page named like Bio / About / Profile / Identity (one shot at "who is this person")
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
   - orphan:            page with 0 inbound links AND not in index.md
   - frontmatter_drift: missing required field (status, updated, tags) on pages that need them
   - stale_superseded:  status: superseded but no link to replacement
   - stale_active:      status: active but updated > 180 days ago

3. SKIP pages with status: archived, superseded, completed, paused.
4. DO NOT flag historical statements clearly labeled as past, code examples,
   aspirational statements, or subjective opinions.
5. BE CONSERVATIVE. False positives waste user time.

OUTPUT FORMAT
Output ONLY a JSON array. One entry per finding. Each entry MUST have:
{
  "signal": "stale_fact" | "broken_wikilink" | "orphan" | "frontmatter_drift" | "stale_superseded" | "stale_active",
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

### Step 3 — Merge and write `data/cleanup-queue.json`

Combine all sub-agent outputs. Assign an incrementing `id` like `2026-05-24-001`. Stamp `category` as `"auto"` for `broken_wikilink`/`index_drift`/`frontmatter_drift`, `"judgment"` for everything else. Sort by `confidence` (high → low). Schema:

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

Save vault selection to `data/preferences.json` for next run's default.

### Step 4 — Launch the review UI

```bash
bash clean-wiki.sh
```

Server starts at `http://localhost:5173`, browser opens directly to the swipe view (no picker — queue is already populated). Tell the user how many findings are queued.

### Step 5 — Wait for the user to finish

The user swipes through cards. When done, they click **Finish** in the UI, which calls `/api/shutdown` — the Flask process exits, the background bash command returns. Block on this. Do not interrupt.

### Step 6 — Apply approved decisions

Read `data/decisions.json` (id → "approve" | "reject" | "defer") and `data/cleanup-queue.json`. For each entry where decision == "approve":

1. Read the target file.
2. Apply the change using **Edit** for text replacements, **Bash `mv`** for archive moves, **Bash `rm`** for deletes.
3. Before each change, capture the file's prior content (for undo).
4. Append to `data/undo-log.jsonl` one record:
```json
{"batch_id": "20260524T...Z", "ts": "ISO8601", "entry_id": "2026-05-24-001",
 "action": "edit-text", "target_file": "abs/path", "before_content": "...full file before..."}
```

After applying, archive the queue + decisions to `data/applied/<batch_id>/`.

### Step 7 — Report

Print to user:
- N changes applied
- M failures (with reasons)
- Undo command: `/clean-wiki --undo` (or describe manual undo path)

### Step 8 — Stop

Do not approve/reject anything yourself. Do not modify pages beyond what the user approved.

## What "undo" means

`/clean-wiki --undo` reads the last batch from `data/undo-log.jsonl`, restores each file from `before_content`, and stamps the entry as undone. No git required.

## Safety properties

- Claude scans read-only. Mutations only after user approves in the browser.
- Per-card review. Each finding requires explicit swipe.
- Undo log per batch — full file content captured before mutation.
- Vault paths configured in `vault-paths.toml`; sub-agents only touch those.

## Sub-commands

```bash
bash clean-wiki.sh           # launch review server (queue must exist)
/clean-wiki                  # full flow (Claude orchestrates)
/clean-wiki --undo           # reverse last batch
```

## Configuration

`config/vault-paths.toml` (gitignored real version, template at `vault-paths.example.toml`):

- Per-vault: `path`, `wiki_subdir`, `index_file`, `archive_dir`, `required_frontmatter`
- UI: `port`, `auto_open_browser`

## Scope (this skill does NOT)

- Create new content (use sync-phone, sync-wiki, dream-skill)
- Modify content without explicit user approval per finding
- Push to GitHub
- Run unattended on a schedule

Full design rationale in [DESIGN.md](./DESIGN.md).
