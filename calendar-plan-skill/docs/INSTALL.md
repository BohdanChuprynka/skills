# Installing calendar-plan-skill

Three install paths. Pick the one matching the runtime you'll use for the cron:

- **Method A — Claude Code plugin marketplace** (recommended for Claude users)
- **Method B — Manual clone** (Claude target, hackable)
- **Method C — Codex CLI** (use the existing Codex automation runner)

After install, run the setup wizard, then a first `--dry-run` cycle to confirm everything is wired correctly.

---

## Prerequisites

| Requirement | Why | Required? |
|---|---|---|
| [Claude Code CLI](https://docs.claude.com/claude-code) | Runs the planner under `--strict-mcp-config`; provides `claude` on `$PATH` | Required for Methods A/B |
| Codex CLI | Runs the planner under its own automation system | Required for Method C |
| Node 18+ (`node`, `npx`) | Spawns the local MCP subprocesses (Notion, Calendar, Gmail, Filesystem) | Required for Tier 1+ |
| Python 3.10+ | `scripts/prep_context.py` and `apply_log.py` | Required |
| A Google account with Calendar | The thing the planner writes to | Required (Tier 1+) |
| A Notion workspace + planner page | Source of the daily task sequence | Optional (Tier 2) |
| An Obsidian vault (or any markdown dir) | Holds the Calendar Context page | Recommended |

Verify the basics:

```bash
claude --help >/dev/null && echo "claude OK"
codex --help  >/dev/null && echo "codex OK"   # only if using Method C
node --version       # 18+ if you want any MCPs
python3 --version    # 3.10+
```

---

## Method A — Claude Code plugin marketplace (recommended)

```bash
/plugin marketplace add BohdanChuprynka/calendar-plan-skill
/plugin install calendar-plan@calendar-plan-marketplace
```

The plugin lands at `~/.claude/skills/calendar-plan/`. From there, run the one-time setup wizard:

```bash
cd ~/.claude/skills/calendar-plan
./setup.sh
```

The wizard will:

1. Verify prereqs (`claude`, `npx`, `python3`).
2. Write `config/settings.conf` (model, timezone, cron hour, Calendar Context path, Notion task-source page title).
3. Copy `examples/planning-preferences.example.md` to `config/planning-preferences.md` — **edit this** to set your real calendar IDs, daily defaults, calendar routing.
4. Optionally walk you through wiring any of the four MCPs (see [`MCP-SETUP.md`](MCP-SETUP.md)). Skip these and you get Tier 0 — draft-mode only, no calendar writes.
5. Seed `memory/memory.md`.
6. Run `doctor.sh` to confirm health.

---

## Method B — Manual clone

For developers, hackers, or anyone who wants to inspect the code first.

```bash
git clone https://github.com/BohdanChuprynka/calendar-plan-skill.git ~/calendar-plan-skill
ln -s ~/calendar-plan-skill/skills/calendar-plan ~/.claude/skills/calendar-plan
cd ~/.claude/skills/calendar-plan
./setup.sh
```

Symlink so Claude Code discovers the skill in its standard skills directory. The repo lives wherever you cloned it; only the link is in `~/.claude/skills`.

Update later:

```bash
cd ~/calendar-plan-skill && git pull
```

The symlink automatically picks up changes.

---

## Method C — Codex CLI

Codex has its own automation system, separate from the Claude plugin marketplace. The installer renders Codex-specific files into `~/.codex/`:

```bash
git clone https://github.com/BohdanChuprynka/calendar-plan-skill.git ~/calendar-plan-skill
bash ~/calendar-plan-skill/codex/setup.sh
```

The Codex installer will:

1. Copy `codex/SKILL.md` and `codex/agents/openai.example.yaml` to `~/.codex/skills/calendar-plan/`.
2. Copy `examples/planning-preferences.example.md` to `~/.codex/skills/calendar-plan/planning-preferences.md` (if not already present — **edit this**).
3. Prompt for placeholder values (Calendar Context path, task source name, timezone, cron hour, working dir, model, reasoning effort) and render `codex/automation.example.toml` into `~/.codex/automations/calendar-plan/automation.toml`.
4. Seed `~/.codex/automations/calendar-plan/memory.md`.

MCP enablement on the Codex side is **separate** — Codex manages MCPs globally in `~/.codex/config.toml` under `[mcp_servers.*]` blocks. The Codex desktop app handles OAuth flows for hosted integrations (Notion, Linear, Figma). See [`MCP-SETUP.md` → "Codex side"](MCP-SETUP.md#codex-side).

---

## Verifying the install

Each target ships a doctor script:

```bash
# Claude target
cd ~/.claude/skills/calendar-plan
./doctor.sh

# Codex target
bash ~/calendar-plan-skill/codex/doctor.sh
```

Expected output looks roughly like:

```
[PASS] claude CLI                       — 1.x.x
[PASS] npx                              — 10.x.x
[PASS] python3                          — Python 3.12.x
[PASS] settings.conf                    — perms 600
[PASS] planning-preferences.md          — exists, no placeholders left
[PASS] mcp-config.json                  — perms 600, no placeholders
[PASS] mcp-config json                  — parses
[PASS] CALENDAR_CONTEXT                 — /Users/.../Calendar Context.md
[PASS] cron-prompt.md                   — /Users/.../prompts/cron-prompt.md
[PASS] memory.md                        — 3 lines
[SKIP] launchd job                      — no plist installed (manual runs only)
all checks pass.
```

A `[SKIP]` for the launchd job is fine — that just means you haven't scheduled it yet. Any `[FAIL]` line points to something to fix; the detail explains what.

---

## First run (Tier 0, free)

Always do a dry run first. No LLM call, no MCPs, no cost — just confirms the prompt renders cleanly and all placeholders resolve.

```bash
./calendar-plan.sh --dry-run
```

This writes the rendered prompt to `/tmp/calendar-plan-prompt.<id>.md` and prints the first 40 lines + the command that would run. Sanity check: no `{{PLACEHOLDER}}` strings should remain in the rendered prompt.

If the dry-run looks right, go to draft mode (real LLM call, NO calendar writes):

```bash
./calendar-plan.sh --mode draft
```

The planner outputs a proposed plan. Read through it. If it looks right, run in auto:

```bash
./calendar-plan.sh --mode auto
```

Inspect the resulting blocks on your Google Calendar and the appended memory entry at `memory/memory.md`. That's the loop.

---

## Adding MCP integrations (Tier 1 and up)

Optional. Skip if Tier 0 already gives you what you need (draft-only mode).

See [`MCP-SETUP.md`](MCP-SETUP.md) for the full walkthrough. Quickest path:

```bash
./setup.sh --mcp
```

The wizard re-runs ONLY the MCP step — prompts for each integration and writes `config/mcp-config.json`. Re-run any time you rotate a token.

---

## Scheduling

> **Run the cron on ONLY ONE runtime.** If both Claude (launchd) and Codex (RRULE) fire on the same evening, the planner will write duplicate blocks.

### Claude target — launchd (macOS)

```bash
cp ~/.claude/skills/calendar-plan/launchd/com.user.calendar-plan.plist.example \
   ~/Library/LaunchAgents/com.user.calendar-plan.plist

# Edit the plist: replace <REPLACE_WITH_ABSOLUTE_PATH_TO_SKILL_DIR> with
# /Users/<you>/.claude/skills/calendar-plan
$EDITOR ~/Library/LaunchAgents/com.user.calendar-plan.plist

launchctl load ~/Library/LaunchAgents/com.user.calendar-plan.plist
launchctl list | grep com.user.calendar-plan       # verify loaded
launchctl start com.user.calendar-plan             # fire immediately for a test
tail -f ~/.claude/skills/calendar-plan/logs/launchd.out
```

Three gotchas:

1. **PATH for `npx`.** launchd jobs run with a minimal PATH. The plist's `EnvironmentVariables.PATH` includes `/opt/homebrew/bin:/usr/local/bin` — adjust if your `npx` lives elsewhere.
2. **Missed fires.** launchd does NOT replay missed `StartCalendarInterval` events for non-system jobs. If the mac is asleep at 22:00, no fire. Workaround: schedule a `pmset` wake just before.
3. **Logs.** `StandardOutPath` / `StandardErrorPath` in the plist need to point at a writable dir. The default uses `logs/launchd.{out,err}` — make sure the parent `logs/` directory exists.

To unload:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.calendar-plan.plist
```

### Codex target — Codex RRULE

No extra step. The installer wrote an RRULE into `~/.codex/automations/calendar-plan/automation.toml` already. Codex picks it up automatically. Verify with:

```bash
codex automations list
codex automations show calendar-plan
```

Codex's scheduler requires the Codex daemon to be running. If you quit Codex entirely, the cron will not fire.

### Linux

The Claude target works on Linux but launchd is mac-only. Use cron or systemd timers instead. Crontab line equivalent:

```cron
0 22 * * * /bin/bash -lc 'TZ=America/New_York PATH=/usr/local/bin:/usr/bin:/bin ~/.claude/skills/calendar-plan/calendar-plan.sh >> ~/.claude/skills/calendar-plan/logs/cron.log 2>&1'
```

The `-lc` loads your shell profile so `nvm`-installed Node is found. Drop if you don't use `nvm`.

---

## Uninstalling

### Method A (plugin marketplace)

```bash
/plugin uninstall calendar-plan
```

### Method B/C (manual or Codex)

```bash
# Claude target
launchctl unload ~/Library/LaunchAgents/com.user.calendar-plan.plist 2>/dev/null
rm -i ~/Library/LaunchAgents/com.user.calendar-plan.plist
rm -i ~/.claude/skills/calendar-plan          # removes the symlink

# Codex target
rm -rI ~/.codex/skills/calendar-plan
rm -rI ~/.codex/automations/calendar-plan
# (the cron auto-disappears when automation.toml is gone)

# Repo (after exporting any memory you want to keep — it's in skills/calendar-plan/memory/)
rm -rI ~/calendar-plan-skill
```

Memory and Calendar Context are **outside** the skill dir — your vault file is untouched. Delete `memory.md` separately if you want to start fresh.

If you set up MCPs and want to fully tear those down, revoke the integration tokens at the source services first — see "Token revocation" in [`MCP-SETUP.md`](MCP-SETUP.md).
