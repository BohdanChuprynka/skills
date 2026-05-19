---
name: dream-skill
description: >
  Use when the user says "run dream", "dream cycle", "reconcile my wiki",
  "check my wiki for stale info", "update my obsidian", "sync my persona vault",
  or wants to verify their personal Obsidian knowledge base is current against
  recent local Claude Code/Codex CLI conversations and connected MCP sources
  (Notion, Calendar, Gmail). Also use when the user wants to schedule, audit, or apply a dream
  report. Do NOT use for code refactors, project documentation, or
  general-purpose note-taking — this only maintains a persona model.
---

# dream-skill — persona-vault reconciliation

Keeps a personal Obsidian knowledge base ("persona vault") accurate by diffing it against recent local Claude Code and Codex CLI conversations plus optional MCP signals (Notion, Calendar, Gmail), then emitting a review-grade dream report.

## When to use

- User says "run dream", "dream cycle", "reconcile my wiki", "check my wiki for stale info"
- User asks whether their persona vault is up to date
- User wants to schedule, audit, or apply a dream report
- User wants to verify life-state facts (roles, projects, goals, schedule, relationships, body) against recent activity

**Do NOT use for:**
- Refactoring code or project documentation
- General-purpose note capture (use a capture skill)
- Querying the vault for an immediate answer (read the vault directly)

## What it does

Periodic reconciliation cycle: extracts user-side signals from local Claude Code and Codex CLI JSONLs in the last N days, snapshots the persona vault (titles, frontmatter, `updated:` dates, `needs_verification:` markers), then makes one LLM call that compares the two against optional MCP sources and emits a structured dream report. The vault is treated as a persona model — stable facts about who the user is, not what they produced.

## How to invoke

From the skill directory:

```bash
bash dream.sh                 # default window (7d)
bash dream.sh --since 14d     # custom window
bash dream.sh --dry-run       # build inputs, skip LLM call
bash dream.sh --model <id>    # override model
```

Paths and behavior come from environment variables and config files (`$DREAM_VAULT_ROOT`, `$DREAM_OUTPUT_DIR`, `<skill-dir>/config/`). See `docs/CONFIGURATION.md`.

## The pipeline

1. **Preprocess conversations** — local Python; user turns prioritized, assistant turns kept as anchors. No LLM tokens.
2. **Snapshot vault** — local Python; walks configured vault paths, extracts frontmatter and stale markers.
3. **Reconcile** — one Claude call with `--strict-mcp-config` so only the skill's configured MCPs load.
4. **Emit report** — markdown written to the configured output directory.

## Output

Report at `$DREAM_OUTPUT_DIR/dream-<YYYY-MM-DD>.md` with four sections:

- `## auto-apply` — proposals with ≥2 evidence channels
- `## needs confirmation` — single-channel proposals
- `## open contradictions` — conflicts surfaced as questions
- `## signals not acted on` — captured for future cycles

Each proposal cites the vault path, current value, proposed value, evidence per channel, and a calibration confidence score.

## Applying changes

Dream cycles emit reports. **They do not edit the vault.** The user reviews the report, then explicitly invokes an apply step (`--apply` flag or conversational request). Without `--apply`, nothing is written to vault pages.

## Configuration

All paths, conversation sources, MCPs, vault subdirectories, and signal patterns live in `<skill-dir>/config/` and environment variables. See `docs/CONFIGURATION.md` for the full reference.

## Cost

~$0.10 per cycle on Sonnet 4.6 with prompt caching. Weekly cadence ≈ $0.30/month. Logged per-run to `<skill-dir>/.usage-log.jsonl`.

## Safety properties

- **Dry-run default mindset.** A bare cycle only emits a report; vault writes require an explicit apply step.
- **Rollback log.** Apply steps record before/after to a rollback JSON; an undo command reverses the last apply.
- **MCP isolation.** `--strict-mcp-config` guarantees only the skill's MCP config loads — daily Claude sessions stay lean, no token bloat from persistent integrations.
- **Persona scope only.** Code/IDE/commit signals are filtered out at preprocess time.

## Common operations

| Action | Command |
|--------|---------|
| Run weekly cycle | `bash dream.sh` |
| Inspect inputs without spending tokens | `bash dream.sh --dry-run` |
| Wider window | `bash dream.sh --since 14d` |
| Apply after review | invoke apply step with `--apply` (see `docs/APPLYING.md`) |
| Undo last apply | run the undo script (see `docs/APPLYING.md`) |
