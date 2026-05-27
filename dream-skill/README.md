<div align="center">

<h1>dream-skill</h1>

<p><strong>Your Obsidian vault auto-syncs to every Claude Code session you close. No manual /sync, no skipped updates, no stale persona.</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/skills?style=flat" alt="License"></a>
  <a href="https://github.com/BohdanChuprynka/skills/stargazers"><img src="https://img.shields.io/github/stars/BohdanChuprynka/skills?style=flat&color=yellow" alt="Stars"></a>
  <img src="https://img.shields.io/badge/version-0.2.0-blue?style=flat" alt="Version 0.2.0">
  <img src="https://img.shields.io/badge/claude--code-plugin-orange?style=flat" alt="Claude Code plugin">
</p>

<p>
  <a href="#install">Install</a> &middot;
  <a href="#how-it-works">How it works</a> &middot;
  <a href="#modes">Modes</a> &middot;
  <a href="#configuration">Config</a> &middot;
  <a href="#safety">Safety</a> &middot;
  <a href="#roadmap">Roadmap</a>
</p>

</div>

---

## The problem

You close Claude Code. The conversation had decisions, preferences, new project context — gone unless you remembered to `/sync-wiki` first. Skip it for a week and future Claude sessions re-ask things you already told them.

## What dream-skill does

Every time you close a Claude Code session with **≥5 user messages**, a SessionEnd hook spawns a background `claude -p` invocation that:

1. Reads the just-closed conversation transcript
2. Strips noise (tool calls, MCP outputs, system reminders)
3. Classifies each candidate fact by **info gain**
4. **Writes confident facts directly** to your Obsidian vault (add-only, with index updates and a per-day undo log)
5. **Queues** uncertain, destructive, or brainstormed facts for your manual review

You never type `/sync-wiki` again. Your vault stays current. You review the queue when you want, fact-by-fact.

## How it works

```
┌────────────────────────────────────────────────────────────────────┐
│  You close Claude Code (⌘W, /exit, quit)                           │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│  SessionEnd hook fires (auto-installed with the plugin)            │
│  → scripts/trigger.sh                                              │
│     - reads transcript path from stdin JSON                        │
│     - counts user messages                                         │
│     - <5 → SKIP silently                                           │
│     - ≥5 → take dedupe lock, export DREAM_* env vars, spawn:       │
│       nohup claude -p "/dream-skill --auto <transcript>" &         │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│  Headless Claude runs SKILL.md auto-mode                           │
│     - scripts/preprocess.sh strips noise                           │
│     - reads $DREAM_CONFIG, vault CLAUDE.md, wiki/index.md          │
│     - classifies each fact into one of 5 buckets                   │
└────────────────────────────────────────────────────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        ▼                         ▼                         ▼
  HIGH CONFIDENCE          DESTRUCTIVE                  GENERAL Q&A
  + additive               UNCERTAIN                    or pure code
        │                  BRAINSTORMED                   │
        ▼                         │                       ▼
  vault-writer.sh                 ▼                   DROP (logged)
  - add-only append         queue.sh
  - idempotent index        - append by bucket
  - undo log entry          - dedupe by title+target
        │                         │
        ▼                         ▼
  Obsidian vault            ~/.claude/dream-skill/
                            queue/pending.md
                                  │
                                  ▼
                  Later: /dream-skill (manual)
                  walks queue → [a]pprove / [e]dit / [s]kip / [d]iscard
```

Three guarantees:
- **Add-only auto writes.** Auto mode never overwrites vault content. Destructive edits go to the queue for your review.
- **Per-day undo log.** `bash apply-undo.sh --date <YYYY-MM-DD>` reverses every auto-write from that day.
- **Fire-and-forget.** The hook never blocks shutdown. Broken installs log to `error.log` and exit silently.

## Install

```bash
/plugin marketplace add BohdanChuprynka/skills
/plugin install dream-skill@skills
```

That's it. The plugin's `hooks/hooks.json` is auto-merged on install — no `~/.claude/settings.json` edits required.

**First run:** create `~/.claude/dream-skill/config.toml` pointing at your vault(s). Minimal example:

```toml
[vaults.me]
root = "/path/to/your/Obsidian/vault"
description = "Identity, projects, decisions"
```

Without a config, auto mode logs an error to `~/.claude/dream-skill/error.log` and exits gracefully — never blocks your session close.

## Modes

| Invocation | What it does |
|---|---|
| *(automatic — on session close)* | SessionEnd hook fires trigger.sh → headless `--auto` capture |
| `/dream-skill` | Walk the queue fact-by-fact: `[a]pprove / [e]dit / [s]kip / [d]iscard / [q]uit` |
| `/dream-skill --auto <transcript>` | Used by the hook. Don't call directly. |
| `/dream-skill --reconcile` | v0.3 stub. Full-vault audit (planned). |
| `/dream-skill --help` | Print modes, env vars, state paths. Exits without writing. |

## Configuration

`~/.claude/dream-skill/config.toml`:

```toml
[vaults.me]
root = "/path/to/me"
description = "Identity, projects, career"

[vaults.projects]
root = "/path/to/projects"
description = "Repos, architecture, gotchas"
```

Each vault root should have a `CLAUDE.md` (the schema Claude reads) and a `wiki/index.md` (the catalog of pages). dream-skill auto-updates the index, idempotently.

**Env overrides** (rarely needed):

| Var | Default | Purpose |
|---|---|---|
| `DREAM_THRESHOLD` | `5` | Min user messages to trigger dispatch |
| `DREAM_LOCK_TTL_SEC` | `600` | Dedupe-lock TTL (suppress duplicate dispatch on multi-window close) |
| `DREAM_HOME` | `~/.claude/dream-skill` | State root |
| `DREAM_CONFIG` | `$DREAM_HOME/config.toml` | Vault config |
| `DREAM_QUEUE_FILE` | `$DREAM_HOME/queue/pending.md` | Queue file |

## State layout

All dream-skill state lives under `~/.claude/dream-skill/`:

```
~/.claude/dream-skill/
├── config.toml              # vault roots (you create this)
├── trigger.log              # SessionEnd dispatch decisions
├── headless.log             # stdout/stderr from spawned claude -p
├── error.log                # broken-install diagnostics
├── log/<date>.md            # per-day human-readable activity log
├── undo/<date>.jsonl        # per-write rollback entries
└── queue/pending.md         # deferred-decision facts
```

This dir survives plugin updates and reinstalls.

## Safety

- **Add-only auto writes** to vault pages (auto mode never deletes or overwrites)
- **Per-day undo log** — full rollback with `apply-undo.sh --date <YYYY-MM-DD>`
- **Dedupe lock** — second close of the same conversation within 10 min is skipped
- **Threshold gate** — sessions with <5 user messages skip dispatch entirely
- **Fire-and-forget hook** — never blocks shutdown; errors stay in `error.log`
- **Reason filter** — `clear` and `prompt_input_exit` skip dispatch (you're not actually done)

## Privacy

- All processing local. Transcripts read directly from `~/.claude/projects/<slug>/*.jsonl` that Claude Code already wrote.
- The only network call is the spawned `claude -p` — identical to any normal Claude Code session.
- No telemetry. No third-party services. Vault paths never leave your machine.

## FAQ

**Q: I closed the same chat in two windows (used `/resume`). Will my vault get polluted?**
No. Three dedupe layers protect you: per-transcript dispatch lock, vault per-line idempotency (`grep -Fxq` exact match), and queue `(title, target)` dedupe. Each unique fact lands exactly once. Worst case: 2x cost on a wasted second headless run that produces zero vault changes.

**Q: How much does each session close cost?**
On a Claude Code subscription (Pro / Max / Team) it's covered — no extra bill. Each dispatch just consumes a small slice of your normal session quota. Approximate per-dispatch usage with the default Haiku 4.5 model: ~30–80K input tokens (preprocessed transcript + vault `CLAUDE.md` + `wiki/index.md`) + ~1–5K output tokens. Translates to roughly $0.01–$0.10 on API billing, or ~5–15% of a single Pro 5-hour window per dispatch. Sessions with <5 user messages skip entirely (override via `DREAM_THRESHOLD`). Switch model with `DREAM_MODEL=claude-sonnet-4-6` for higher-quality classification at ~5x the spend.

**Q: Will it fire if I just open Claude and close without typing anything?**
No. Threshold gate skips silently when user-message count is below `DREAM_THRESHOLD` (default 5).

**Q: What if Claude Code crashes or I force-quit?**
SessionEnd hook only fires on `/exit`, ⌘W, or normal quit — not on crash. The dropped session's facts are missed until you reopen and run `/dream-skill` manually (which sweeps the queue) or `/sync-wiki` (if you still have that skill).

**Q: How do I disable temporarily?**
Set `DREAM_THRESHOLD=99999` in your shell env, or comment out the SessionEnd entry in `~/.claude/settings.json` (or remove the plugin).

**Q: Where do auto-writes go? How do I roll them back?**
Confident facts append to your Obsidian vault pages (add-only). Every write is logged in `~/.claude/dream-skill/undo/<date>.jsonl`. Roll back a full day with `bash scripts/apply-undo.sh --date YYYY-MM-DD` — originals preserved.

## Roadmap

- **v0.2** (current) — per-conversation auto-on-close, manual queue review
- **v0.2.1** (next) — first-run setup wizard, cost guard via token counter, JSON-shaped headless log
- **v0.3** — `/dream-skill --reconcile` for periodic full-vault audit against accumulated session data

## Docs

- [SKILL.md](skills/dream-skill/SKILL.md) — runtime instructions Claude reads
- [PLAN.md](PLAN.md) — original v0.2 build plan
- [HARVEST.md](HARVEST.md) — patterns ported from v0.1

## License

MIT
