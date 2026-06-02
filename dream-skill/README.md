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

Every time you close a Claude Code session with **≥1 user message**, a SessionEnd hook spawns a background `claude -p` invocation that:

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
│     - counts genuine user messages (real typed turns)              │
│     - 0 or unchanged since last close → SKIP                       │
│     - new message → export DREAM_* env vars, spawn:                │
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
| `/dream-skill --ignore` | Mark the current chat **private** — it's never recorded on close (undo: `/dream-skill --unignore`) |
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
| `DREAM_THRESHOLD` | `1` | Min genuine user messages to trigger dispatch |
| `DREAM_MODEL` | `claude-haiku-4-5` | Model for the headless classifier run |
| `DREAM_HOME` | `~/.claude/dream-skill` | State root |
| `DREAM_CONFIG` | `$DREAM_HOME/config.toml` | Vault config |
| `DREAM_QUEUE_FILE` | `$DREAM_HOME/queue/pending.md` | Queue file |

## State layout

All dream-skill state lives under `~/.claude/dream-skill/`:

```
~/.claude/dream-skill/
├── config.toml              # vault roots (you create this)
├── trigger.log              # ALL dispatch outcomes: SKIP / DISPATCH / SPAWNED / COMPLETED / ERROR / WARNING
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
- **Count-delta gate** — re-closing a conversation with no new messages is skipped (resume and type nothing → skip; type anything → re-capture)
- **Threshold gate** — sessions with no genuine user messages skip dispatch entirely (raise `DREAM_THRESHOLD` to require more)
- **Fire-and-forget hook** — never blocks shutdown; errors stay in `error.log`
- **Reason filter** — `clear` and `prompt_input_exit` skip dispatch (you're not actually done)
- **Failure logging** — every outcome (success, skip, error, silent abort) lands in `~/.claude/dream-skill/trigger.log`. Grep for `ERROR` or `WARNING` to see failures. Zero notifications, zero context pollution.

## Privacy

- All processing local. Transcripts read directly from `~/.claude/projects/<slug>/*.jsonl` that Claude Code already wrote.
- The only network call is the spawned `claude -p` — identical to any normal Claude Code session.
- No telemetry. No third-party services. Vault paths never leave your machine.

**Keeping a chat private.** Some conversations you just don't want in your vault. Type **`/dream-skill --ignore`** in that chat — when you close it, dream-skill skips it entirely: no headless run, no vault writes, no chat content or title recorded (just a `skipped — marked private` line in the day's `dream-reports` file so you can confirm it worked). Changed your mind? **`/dream-skill --unignore`** re-enables recording (latest one wins). The opt-out ships with the plugin — no global config or `CLAUDE.md` setup required.

## FAQ

**Q: I closed the same chat in two windows (used `/resume`). Will my vault get polluted?**
No. Three dedupe layers protect you: the per-transcript count-delta gate (re-dispatch only when you've added a message), vault per-line idempotency (`grep -Fxq` exact match), and queue `(title, target)` dedupe. Each unique fact lands exactly once. Worst case: 2x cost on a wasted second headless run that produces zero vault changes.

**Q: How do I confirm it ran, from inside Obsidian?**
Every run appends a one-line entry to a `dream-reports/dream-<date>.md` file alongside your vault: `wrote N` with the captured bullets, `ran, 0 writes` when nothing was persona-worthy, or `skipped` with the reason. Glance at today's file to see what each close captured — no leaving Obsidian.

**Q: How much does each session close cost?**
On a Claude Code subscription (Pro / Max / Team) it's covered — no extra bill. Each dispatch just consumes a small slice of your normal session quota. Approximate per-dispatch usage with the default Haiku 4.5 model: ~30–80K input tokens (preprocessed transcript + vault `CLAUDE.md` + `wiki/index.md`) + ~1–5K output tokens. Translates to roughly $0.01–$0.10 on API billing, or ~5–15% of a single Pro 5-hour window per dispatch. Sessions with no user messages skip entirely; raise `DREAM_THRESHOLD` if you want to gate out short throwaway sessions too. Switch model with `DREAM_MODEL=claude-sonnet-4-6` for higher-quality classification at ~5x the spend.

**Q: Will it fire if I just open Claude and close without typing anything?**
No. Threshold gate skips silently when the genuine user-message count is below `DREAM_THRESHOLD` (default 1, so only sessions with zero typed messages skip).

**Q: What if Claude Code crashes or I force-quit?**
SessionEnd hook only fires on `/exit`, ⌘W, or normal quit — not on crash. The dropped session's facts are missed until you reopen and run `/dream-skill` manually (which sweeps the queue) or `/sync-wiki` (if you still have that skill).

**Q: How do I disable temporarily?**
Set `DREAM_THRESHOLD=99999` in your shell env, or comment out the SessionEnd entry in `~/.claude/settings.json` (or remove the plugin).

**Q: Where do auto-writes go? How do I roll them back?**
Confident facts append to your Obsidian vault pages (add-only). Every write is logged in `~/.claude/dream-skill/undo/<date>.jsonl`. Roll back a full day with `bash scripts/apply-undo.sh --date YYYY-MM-DD` — originals preserved.

**Q: How do I know if dream-skill failed silently?**
Everything lands in `~/.claude/dream-skill/trigger.log`. Three failure types get distinct lines:

| Line | Meaning |
|---|---|
| `ERROR source=trigger ...` | trigger.sh pre-flight failure (claude CLI missing, etc.) |
| `ERROR source=claude-p code=N ...` | `claude -p` exited non-zero (API error, timeout, crash) |
| `WARNING kind=orphan ...` | A spawn never reported completion — silent abort inside the headless skill |

To inspect:

```bash
tail ~/.claude/dream-skill/trigger.log              # last 10 events
grep -E "ERROR|WARNING" ~/.claude/dream-skill/trigger.log   # all failures
```

Legitimate skips (below threshold, no new messages, empty transcript) appear as `SKIP` lines — not failures. No popups, no Claude-context injection — pure log output.

## Troubleshooting

**Diagnostic-first checklist.** Run these three before assuming a bug:

```bash
tail ~/.claude/dream-skill/trigger.log         # most recent dispatches + outcomes
cat ~/.claude/dream-skill/headless.log         # claude -p stdout/stderr
cat ~/.claude/dream-skill/error.log            # broken-install diagnostics (Rule 3)
```

Then match symptom to fix.

### Hard requirements (verify install)

```bash
claude --version            # any v1.x or v2.x works
which jq                    # must return a path
uname -s                    # Darwin or Linux (Windows: use WSL2 or Git Bash)
ls ~/.claude/dream-skill/   # config.toml + queue/ + log/ + undo/ dirs must exist
```

If `jq` missing → `brew install jq` (Mac) or `apt install jq` (Debian/Ubuntu).

### Tier 1 — Critical (blocks dispatch entirely)

| Symptom | Cause | Fix |
|---|---|---|
| Nothing happens on session close, trigger.log unchanged | Plugin hooks didn't auto-merge into `~/.claude/settings.json` | Manually add the SessionStart + SessionEnd entries from `hooks/hooks.json` |
| `ERROR source=trigger code=127 msg=claude-cli-missing` | `claude` CLI not on PATH | Reinstall Claude Code; `which claude` to verify |
| `ERROR source=claude-p code=N` immediate (<5s) | claude not authenticated (no API key / no subscription session) | `claude login` or set `ANTHROPIC_API_KEY` |
| Scripts fail with `jq: command not found` | `jq` not installed | `brew install jq` / `apt install jq` |
| Windows user — scripts won't run at all | Native cmd/PowerShell has no bash | Use WSL2 or Git Bash; dream-skill is bash-only |

### Tier 2 — Functional but degraded

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR source=skill code=1 msg=env-validation-failed` every run | No `~/.claude/dream-skill/config.toml` | Create it. Minimum: one `[vaults.X]` block with `root = "/path/to/vault"` |
| Auto-mode runs (logs COMPLETED) but writes nothing useful | Vault has no `CLAUDE.md` or `wiki/index.md` — LLM can't route facts | Create both files in vault root, even empty stubs |
| `WARNING kind=orphan` after every session | `claude -p` exits 0 but headless LLM aborts | Check `~/.claude/dream-skill/headless.log` for the reason (usually permission denial, model error, or SKILL.md prompt issue) |
| `ERROR source=claude-p code=N` says "model not found" | Pinned `claude-haiku-4-5` not available on user's plan | Override: `export DREAM_MODEL=claude-sonnet-4-6` or earlier haiku build |
| Subscription rate-limit hit mid-session | Pro/Max 5h quota exhausted | Raise `DREAM_THRESHOLD` so trivial sessions skip; or set cheaper `DREAM_MODEL` |
| Multiple dispatches, all fast `COMPLETED` but zero queue/vault output | LLM dropping everything as recursive/no-info — may be over-firing | Tune SKILL.md Step 3 Bucket C/D rules (open issue if persistent) |

### Tier 3 — Edge cases (rare)

| Symptom | Cause | Fix |
|---|---|---|
| A chat won't re-capture even after you add messages | Stale seen-count in `~/.claude/dream-skill/.locks/<hash>` | Self-heals on the next close (gate re-dispatches on any count change). To force-reset all baselines: `rm -rf ~/.claude/dream-skill/.locks/` |
| Hook fires from wrong cwd, paths break | `$CLAUDE_PLUGIN_ROOT` unset (rare for plugin install) | trigger.sh falls back to its own `dirname` — usually works. If not, hardcode absolute path in settings.json hook command |
| Vault on iCloud Drive, write fails or corrupts | iCloud sync conflict / file open in another app | Move vault outside iCloud, or use Obsidian's local-only mode |
| Vault has 1000+ pages, headless run slow | SKILL.md loads `wiki/index.md` — large indexes inflate context | Split into per-subdir indexes; trim main index |
| Disk full — silent append failures | `>>` returns non-zero, swallowed by `|| true` guards | `df -h ~/.claude/` to verify; free disk |
| Mixed-case path mismatch on Linux | macOS case-insensitive default vs Linux case-sensitive | Match case in `config.toml` `root = ...` exactly to actual directory name |
| `tac` not on system, undo loop slow | macOS lacks `tac` (Linux-only) — awk fallback used | Already handled; only matters if awk also missing |

### Tier 4 — Known limitations (won't fix in v0.2)

| Limitation | Workaround |
|---|---|
| Claude Code crash → SessionEnd never fires | Manually run `/dream-skill --auto <transcript-path>` afterward |
| Two simultaneous closes (same transcript, <100ms apart) | Both reads see the same seen-count, so a sub-100ms race may double-dispatch. Vault-writer idempotency + queue dedup catch the downstream duplicates anyway |
| Plugin updated mid-session | Old hook config in memory stays active for current session; new sessions get new behavior |
| Transcript .jsonl written async by Claude Code | If hook fires before file flushed, trigger.sh logs `SKIP file-not-found`. Acceptable — next session usually has the file |

### Still stuck?

Open an issue at <https://github.com/BohdanChuprynka/skills/issues> with:
- Output of the diagnostic-first 3 commands above
- `claude --version`
- `uname -a`
- Last ~50 lines of `~/.claude/dream-skill/trigger.log`

## Roadmap

- **v0.2** (current) — per-conversation auto-on-close, manual queue review, in-vault progress reports
- **v0.2.1** (next) — first-run setup wizard, cost guard via token counter, JSON-shaped headless log
- **v0.3** — `/dream-skill --reconcile` for periodic full-vault audit against accumulated session data

## Docs

- [SKILL.md](skills/dream-skill/SKILL.md) — runtime instructions Claude reads
- [PLAN.md](PLAN.md) — original v0.2 build plan
- [HARVEST.md](HARVEST.md) — patterns ported from v0.1

## License

MIT
