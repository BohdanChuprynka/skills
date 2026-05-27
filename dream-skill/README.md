# dream-skill

> Auto-record your Claude Code conversations to your Obsidian vault.
> Confident facts written automatically on session close;
> uncertain or destructive edits queued for your manual review.

## Why

Your Obsidian persona vault — who you are, what you're working on, what
you've decided — goes stale fast. Manually running `/sync-wiki` after
every conversation is friction. Skipping it for a week means future
Claude sessions don't know what's current about you, so they re-ask
context you already gave.

dream-skill fixes this by **firing automatically** every time you close
Claude Code. A SessionEnd hook (installed automatically with the plugin)
runs a script that:

1. Checks if the conversation was long enough to matter (≥10 user messages by default)
2. Spawns a headless `claude -p` in the background to extract info-gain
3. Writes confident facts directly to your vault (add-only)
4. Queues uncertain, destructive, or brainstormed facts for your manual review

You never type `/sync-wiki` again. Your vault stays current. You review
the queue when you want, fact-by-fact.

## How it works

```
[You close Claude Code window]
   │
   ▼
[SessionEnd hook fires]   (auto-installed; no settings.json edits)
   │
   ▼
[scripts/trigger.sh]
   ├── transcript < 10 user messages → SKIP silently
   └── ≥10 user messages → spawn background `claude -p "/dream-skill --auto <transcript>"`
                              │
                              ▼
                    [Headless Claude runs SKILL.md auto mode]
                              │
                              ▼
              [scripts/preprocess.sh]  strip tool calls, MCP raw output,
                                       system reminders, hook content
                              │
                              ▼
              [LLM classifies each candidate fact]
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
   HIGH CONFIDENCE   DESTRUCTIVE/UNCERTAIN   GENERAL Q&A
   + additive       /BRAINSTORMED            (drop unless
        │                  │                  signal-bearing)
        ▼                  ▼
   [vault-writer.sh]   [queue.sh]
   add-only append     append to bucket
   + idempotent index  in pending.md
   + undo log entry

[Later, you run /dream-skill manually]
   │
   ▼
   walk queue fact-by-fact:
   [a]pprove / [e]dit / [s]kip / [d]iscard / [q]uit
```

## Install

```bash
/plugin marketplace add BohdanChuprynka/skills
/plugin install dream-skill@dream-skill-marketplace
```

The plugin's `hooks/hooks.json` is auto-merged on install. No edits to
`~/.claude/settings.json` required.

On first run (manual mode), dream-skill prompts you for your vault root(s)
and writes `~/.claude/dream-skill/config.toml`. In auto mode, if the
config is missing, it logs an error and exits gracefully — never blocks
your session close.

## Configuration

`~/.claude/dream-skill/config.toml`:

```toml
[vaults.me]
root = "/path/to/your/Obsidian/vault"
description = "Identity, skills, experience, projects"

[vaults.projects]
root = "/path/to/your/projects/vault"
description = "Repos, architecture, goals, gotchas"
```

Each vault root should contain a `CLAUDE.md` (the vault's schema/conventions
that Claude reads) and a `wiki/index.md` (the catalog of pages). dream-skill
auto-updates `wiki/index.md` with links to new pages (idempotent — won't
re-link or clobber existing descriptions).

Environment overrides:

| Var | Default | Purpose |
|---|---|---|
| `DREAM_THRESHOLD` | `10` | Min user messages to trigger dispatch |
| `DREAM_QUEUE_FILE` | `~/.claude/dream-skill/queue/pending.md` | Queue file location |
| `DREAM_LOG` | `~/.claude/dream-skill/trigger.log` | Trigger decision log |

## Usage

### Auto (the default — no command needed)

Just close Claude Code. The hook fires automatically.

### Manual review of queued items

```
/dream-skill
```

Walks `pending.md` fact-by-fact. For each entry: `[a]pprove`, `[e]dit`,
`[s]kip`, `[d]iscard`, `[q]uit`.

### Undo auto-mode writes

```bash
~/.claude/plugins/.../dream-skill/scripts/apply-undo.sh --date 2026-05-27
```

Reverses every vault-writer write from that day. Originals preserved.
Processed log moved to `<log>.applied-<timestamp>` so it can't double-apply.

## State layout

All dream-skill runtime state lives under `~/.claude/dream-skill/`:

```
~/.claude/dream-skill/
├── trigger.log               # SessionEnd dispatch decisions
├── headless.log              # stdout/stderr from spawned claude -p
├── log/<YYYY-MM-DD>.md       # human-readable auto-write log per day
├── undo/<YYYY-MM-DD>.jsonl   # rollback entries
├── queue/pending.md          # deferred-decision facts
└── config.toml               # vault roots
```

This dir survives plugin updates and reinstalls.

## Privacy

- Nothing leaves your machine except the headless `claude -p` invocation
  (same network behavior as any normal Claude Code session)
- Transcripts read directly from `~/.claude/projects/<slug>/*.jsonl`
  that Claude Code already wrote
- No telemetry, no third-party services
- Vault paths are local-only; never sent anywhere

## Safety

- **Add-only auto-writes:** auto mode never overwrites or deletes vault content.
  Destructive edits go to the queue for your manual review.
- **Undo log:** every auto-write recorded; full per-day rollback available.
- **Threshold gate:** trivial conversations (<10 user messages) skipped.
- **Fire-and-forget:** hook never blocks your session close. Errors logged silently.

## Roadmap

- **v0.2.0** (this release): per-conversation auto-on-close. Manual queue review.
- **v0.3.0** (planned): `/dream-skill --reconcile` — full-vault audit against
  accumulated session data; multi-source signals (Notion, Calendar, Gmail).

## Cross-references

- `HARVEST.md` — patterns ported from v0.1
- `PLAN.md` — v0.2 build plan
- `skills/dream-skill/SKILL.md` — runtime instructions Claude reads

## License

MIT
