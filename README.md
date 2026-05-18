<div align="center">

<h1>calendar-plan-skill</h1>

<p><strong>plan tomorrow tonight — google calendar, notion, gmail, and a local context page, written by a model that knows your daily rhythm</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/calendar-plan-skill?style=flat" alt="License"></a>
  <a href="https://github.com/BohdanChuprynka/calendar-plan-skill/stargazers"><img src="https://img.shields.io/github/stars/BohdanChuprynka/calendar-plan-skill?style=flat&color=yellow" alt="Stars"></a>
  <a href="https://github.com/BohdanChuprynka/calendar-plan-skill/releases"><img src="https://img.shields.io/github/v/release/BohdanChuprynka/calendar-plan-skill?style=flat&include_prereleases" alt="Version"></a>
</p>

<p>
  <a href="#the-problem">Problem</a> &middot;
  <a href="#what-calendar-plan-does">What it does</a> &middot;
  <a href="#how-it-works">How</a> &middot;
  <a href="#install">Install</a> &middot;
  <a href="#example-output">Example</a> &middot;
  <a href="#configuration">Config</a> &middot;
  <a href="#cost">Cost</a>
</p>

</div>

---

## The problem

You have a Notion page with tomorrow's goals. A Google calendar with three sub-calendars and a moving exam schedule. A Gmail inbox that quietly tells you someone needs a reply by morning. A markdown note in Obsidian that says "low energy this week, no gym Thursday." Every evening you reconcile all of that into a day plan — and most evenings, you don't, and tomorrow gets reactive.

Anthropic's Claude desktop has a "Cowork / Automations" feature for this kind of thing, and so does Codex CLI. Both are scoped to their host app, both rely on global MCP enablement that pollutes every daily session with Notion/Calendar/Gmail tools, and both are opaque when something breaks.

calendar-plan-skill is the same idea, owned by you. One markdown file holds the prompt. One JSON file holds the MCP credentials, scoped to this skill alone. One script renders it and calls Claude (or Codex). The scheduler is plain launchd or a Codex RRULE. If a connector fails, the planner pauses with a memory entry — not silently writes garbage.

## What calendar-plan does

- Reads tomorrow's fixed events across every configured Google sub-calendar.
- Pulls the next day's task sequence from a private Notion page.
- Scans recent Gmail for deadlines and obligations that aren't yet on a calendar.
- Reads a local Obsidian "Calendar Context" markdown page for one-off modifiers (low energy, travel days, exam constraints) and durable upcoming items.
- Drafts a small number of useful planning blocks — meals, deep work, commute, recovery — sized to your real rhythm, not a packed ideal day.
- In `auto` mode, writes the safe blocks directly to the matching sub-calendar (`School` / `Personal` / `Work` / primary). Pauses for risky changes.
- Appends an append-only memory entry per run: which connectors worked, what was written, what got paused, what to investigate.
- Runs under `--strict-mcp-config` on the Claude side, so the planner's tokens never leak into your daily Claude Code sessions.

## How it works

```
fixed calendar events          notion task page             recent gmail               local calendar context
(google calendar mcp)          (notion mcp)                 (gmail mcp)                 (filesystem mcp / --add-dir)
       |                              |                            |                            |
       +-------------------------+----+----------------------------+----------------------------+
                                 |
                                 v
                       prep_context.py (placeholder substitution, no LLM)
                                 |
                                 v
                  claude --mcp-config <skill>/config/mcp-config.json --strict-mcp-config
                                 |
                                 v
                draft proposal      OR      apply safe blocks to google calendar (auto mode)
                                 |
                                 v
                       apply_log.py (parse log, append to memory.md)
```

Four stages. One paid LLM call (~$0.05-$0.15 on Sonnet 4.6 with cache hits). Everything else is local Python or the MCP subprocess loop.

Both runtime targets share the same `prompts/cron-prompt.md` body. Edit once, both planners pick it up next run.

## Example output

A real auto-mode run looks like this (names changed):

```
target_date: 2026-05-19 (Mon)
mode: auto
connectors: google-calendar ok, notion ok, gmail ok, filesystem ok

Fixed events read:
  School      08:30-15:30  Regular school day
  Personal    19:00-20:00  Run with friend (location: park)

Notion task sequence (12-Week Planner):
  1. AP Calc problem set
  2. ML lecture 4
  3. Outreach: 3 founders
  4. Github commit

Calendar Context modifiers:
  - low-energy week, prefer one deep block over many small

Email-derived obligations:
  - Reply to advisor about thesis topic (received 2026-05-18, expects answer by Mon)

Wrote (auto):
  Personal    16:00-16:30  Landing buffer
  Personal    16:30-17:30  Outreach: 3 founders            (Notion seq #3)
  School      17:45-19:00  AP Calc problem set             (Notion seq #1)
  Personal    20:15-21:30  Dinner + reset
  Work        21:30-23:00  ML lecture 4 + commit           (Notion seq #2,#4 merged: low-energy modifier)

Paused (no write):
  - Thesis advisor reply: ambiguous priority; surfaced for user decision.

Re-query post-write: no overlaps, no stale duplicates.
```

The memory.md entry written for this run becomes the input to the NEXT run, so the planner remembers that you merged ML+commit into one block and stops trying to split them.

## Install

Three commands. The installer wires both Claude and Codex from one config file.

```bash
git clone https://github.com/BohdanChuprynka/calendar-plan-skill.git ~/calendar-plan-skill
cd ~/calendar-plan-skill
bash setup.sh
```

The first run of `setup.sh` creates `local.env` from a template, then exits. Open it, fill in your values (paths, Notion token, Google OAuth file locations), and re-run `bash setup.sh`. After that, the installer:

- Symlinks the skill into `~/.claude/skills/calendar-plan/` (Claude picks it up automatically)
- Copies the Codex skill files into `~/.codex/skills/calendar-plan/` (restart Codex to discover)
- Generates `mcp-config.json`, `settings.conf`, and `automation.toml` from your `local.env`
- Seeds a `planning-preferences.md` for your calendar IDs (edit this once)
- Runs a health check

**The two files you actually edit:**

| File | What goes in it |
|---|---|
| `local.env` | Paths, tokens, IDs, timezone — basically everything specific to you |
| `~/.codex/skills/calendar-plan/planning-preferences.md` | Calendar routing rules, daily defaults |

Everything else is generated. Re-run `bash setup.sh` whenever you edit `local.env`.

Full walkthrough with troubleshooting: [docs/INSTALL.md](docs/INSTALL.md).

## Quickstart

After install:

```bash
# Dry-run (no LLM call, no calendar writes)
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --dry-run

# Draft mode (real LLM call, NO calendar writes — review the plan)
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode draft

# Live auto mode (writes safe blocks to Google Calendar)
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode auto
```

Or invoke it as a slash command in any Claude Code or Codex session: `/calendar-plan`.

Optional — schedule the daily cron (macOS launchd):

```bash
cp ~/.claude/skills/calendar-plan/launchd/com.user.calendar-plan.plist.example \
   ~/Library/LaunchAgents/com.user.calendar-plan.plist
# Edit the plist (replace the SKILL_DIR placeholder), then:
launchctl load ~/Library/LaunchAgents/com.user.calendar-plan.plist
```

## What you'll need

- **Claude Code CLI** (logged in) — for the Claude target. Install: https://docs.claude.com/claude-code.
- **Codex CLI** (run at least once) — only if you're using the Codex target.
- **Node 18+** (`npx`) — for the MCP subprocesses.
- **Python 3.10+** — for `prep_context.py` / `apply_log.py`.
- **A Google account** with Calendar (and optionally Gmail). OAuth desktop-client credentials, set up once.
- **(Optional) A Notion workspace** with a daily/weekly planner page and an internal integration token.
- **(Optional) An Obsidian vault** with a `Calendar Context.md` page. Any markdown file works — Obsidian is just a convenient editor.

## Compatibility

Two runtimes are first-class supported:

- **Claude Code CLI** — invoked as `claude --mcp-config ... --strict-mcp-config`. The `--strict-mcp-config` flag is load-bearing for token isolation.
- **Codex CLI** — invoked via Codex's own automation runner (`~/.codex/automations/<id>/automation.toml`).

Other agent runtimes (Cursor, Gemini, etc.) are not verified. The prompt body in `prompts/cron-prompt.md` is plain English with explicit placeholders, so adapting it to a different runtime is straightforward — see [CONTRIBUTING.md](CONTRIBUTING.md) for guidance.

## Configuration

The Claude target reads one config file and a handful of env vars:

```bash
# Required
CALENDAR_CONTEXT="$HOME/Documents/Obsidian/me/wiki/Calendar Context.md"

# Sensible defaults
MODEL="claude-sonnet-4-6"
TIMEZONE="America/New_York"
CRON_HOUR="22"
DEFAULT_MODE="auto"
TASK_SOURCE_NAME="12-Week Planner"
```

These live in `config/settings.conf` after `./setup.sh` runs. The planning preferences (calendar IDs, daily defaults, calendar routing) live in `config/planning-preferences.md` — copied from the sanitized `examples/planning-preferences.example.md` template.

Full reference: CLI flags, env vars, config files, common recipes — see [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## MCP integrations (optional)

calendar-plan-skill works in three tiers. Pick how far you want to go.

**Tier 0** — `--mode draft` with no MCPs. Calendar Context page + Notion (via `--add-dir`) are still readable. The planner can read but cannot write to Google Calendar. Useful for first-time validation, or as a daily preview if you prefer to copy blocks over manually.

**Tier 1** — add the **Google Calendar MCP**. This is the minimum viable cron — the planner can now actually write blocks. All other connectors are optional augmentations.

**Tier 2** — add any combination of **Notion**, **Gmail**, and **Filesystem** MCPs. Each is independently optional. More channels means more accurate sequence reads, fewer "Pause: missing task source" memory entries, and richer email-derived obligations.

Critical: `calendar-plan.sh` launches Claude with `--mcp-config <skill>/config/mcp-config.json --strict-mcp-config`. Only the skill's MCPs load. Your daily Claude Code session is untouched — no token bloat, no context pollution.

Per-server setup walkthroughs (auth, tokens, scopes) live in [docs/MCP-SETUP.md](docs/MCP-SETUP.md).

## Cost

Roughly **$0.05-$0.15 per run on Sonnet 4.6 with prompt caching enabled**. Daily cadence ≈ $1.50-$4.50/month.

The prompt stays mostly cache-resident — SKILL.md and planning-preferences.md don't change between runs. First-run cost can be 2-3x higher because the cache is cold. Watch `logs/run-<ISO>.log` for actual per-cycle numbers.

Opus 4.7 is overkill for typical days but can be worth it on weeks with multi-exam + travel + meeting collisions — bump `MODEL` in `settings.conf` or pass `--model claude-opus-4-7` for one run.

## Safety

- **Draft mode is the default first run.** `./setup.sh` defaults `DEFAULT_MODE="auto"` only because the cron needs it; the first manual run should always be `--mode draft` to inspect the plan before writing.
- **Auto mode is additive only.** The planner never deletes events. Never rewrites non-planning events. Never modifies the Calendar Context page. These are hard prompt constraints, not soft suggestions.
- **MCP isolation.** `--strict-mcp-config` guarantees the planner's MCPs do not leak into other Claude Code sessions. Tokens live in `config/mcp-config.json` (chmod 600, gitignored).
- **Append-only memory.** Run summaries append to `memory/memory.md`. Compaction is opt-in (`./scripts/compact_memory.py`). The planner reads memory at the start of each run, so wiping it loses preference signal.
- **Graceful degradation on connector failure.** If Notion is down or Gmail's tool isn't exposed, the planner pauses with a memory entry rather than writing a partial plan. The next morning's review surfaces the gap.
- **No autonomous firing.** The installer does not register a cron. You opt in by copying the launchd plist (Claude target) or by letting Codex's RRULE pick up the rendered automation.toml (Codex target).

## FAQ

**Do I need both runtimes?**
No. Pick one for the cron. The Claude target is recommended if you want token isolation and full ownership of the schedule (launchd). The Codex target is recommended if you already live in Codex and want the planner to share the OAuth integrations the desktop app already manages.

**Can I run without Notion?**
Yes. The planner reads Notion via MCP, but if the connector is unavailable it falls back to a conservative scaffold built from calendar state + Calendar Context + daily defaults. Configured behavior: pause only when the missing source could materially change the day.

**What if the planner writes blocks I don't want?**
Edit them or delete them in Google Calendar. The next run reads existing blocks and treats your edits/deletions as preference signal — the planner will not re-add a block you deleted, and learns from merges.

**Why a separate MCP config instead of using my existing one?**
Because cross-pollution is bad. Your daily Claude Code session probably has its own MCPs (project-specific, work-specific). Loading Notion/Gmail there leaks personal context into work contexts. calendar-plan's MCPs only exist for the duration of one run.

**The cron didn't fire last night — what happened?**
launchd does NOT replay missed `StartCalendarInterval` events for non-system jobs. If the mac was asleep at 22:00, no fire. Two fixes: (1) keep the mac awake at the configured time, (2) use `pmset` to schedule a wake just before. The Codex target has a similar limitation — the Codex daemon must be running for RRULEs to fire.

**Can I use Opus for this?**
Yes — pass `--model claude-opus-4-7`. Typical evenings don't need it, but Opus's deeper reasoning is worth it for weeks with conflicting exams + travel + immovable meetings.

## Contributing

PRs welcome. The repo is small and the surface is intentionally limited. Read [CONTRIBUTING.md](CONTRIBUTING.md) first — it lists which file to edit when you want to change behavior, the local dev loop, and how to test a skill change end-to-end without burning your real calendar.

## Acknowledgments

- The Codex CLI automation system, which made the first version of this skill possible.
- Anthropic's Claude Code, the plugin marketplace format, and `--strict-mcp-config`.
- `dream-skill` for the MCP-isolation pattern and the tier model.

## License

MIT — see [LICENSE](LICENSE).

---

Built by [Bohdan Chuprynka](https://github.com/BohdanChuprynka).
