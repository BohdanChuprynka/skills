# calendar-plan-skill

Daily calendar planner that runs as a skill in **Claude Code** *and* as a Codex CLI automation, with isolated per-skill MCP credentials. One source of truth for the prompt; two runtimes pick it up.

## Mental model

The planner has one job each evening: turn your fixed calendar, your task source (a Notion page), recent email signals, and a local Obsidian "Calendar Context" note into a small number of useful blocks on tomorrow's calendar.

Two surfaces, same brain:

- **Claude target** (`claude/`) — a skill at `~/.claude/skills/calendar-plan/`. Triggered by `/calendar-plan` in any Claude Code session, OR fired by launchd at 22:00 local time. Uses `claude --mcp-config <file> --strict-mcp-config` so only this skill's MCPs load. Daily Claude sessions stay lean — no token bloat from Notion/Calendar/Gmail integrations leaking into every context.
- **Codex target** (`codex/`) — a skill at `~/.codex/skills/calendar-plan/` plus a cron automation at `~/.codex/automations/calendar-plan/`. Same prompt body, executed under Codex's own RRULE scheduler.

Both targets read the **same prompt** (`prompts/cron-prompt.md`) and the **same example planning preferences** (`examples/planning-preferences.example.md`). Edit the prompt once; both runtimes pick it up on next run.

## Paths (after install)

| Path | What lives there | Source |
|---|---|---|
| `<repo>/prompts/cron-prompt.md`                | Scheduled-run prompt template with `{{PLACEHOLDERS}}` | Edit-only |
| `<repo>/examples/*.example.md`                 | Sanitized templates for prefs / memory / calendar context | Edit-only |
| `~/.claude/skills/calendar-plan/SKILL.md`      | Discoverability metadata for `/calendar-plan` | Installed |
| `~/.claude/skills/calendar-plan/config/`       | **REAL** mcp-config.json, planning-preferences.md, settings.conf — chmod 600, **gitignored** | Created by setup.sh |
| `~/.claude/skills/calendar-plan/memory/memory.md` | Append-only run memory | Created by first run |
| `~/.claude/skills/calendar-plan/logs/`         | Per-run logs and launchd out/err | Created by first run |
| `~/Library/LaunchAgents/com.user.calendar-plan.plist` | macOS cron job | Installed manually from `claude/launchd/*.example` |
| `~/.codex/skills/calendar-plan/`               | Codex-side skill files | Installed by codex/setup.sh |
| `~/.codex/automations/calendar-plan/`          | Codex-side cron + memory | Installed by codex/setup.sh |

## Workflow

### 1. Clone

```bash
git clone git@github.com:<you>/calendar-plan-skill.git ~/calendar-plan-skill
cd ~/calendar-plan-skill
```

### 2. Install the Claude target

```bash
# Symlink (recommended) — edits to the repo propagate to the skill
ln -s "$PWD/claude" ~/.claude/skills/calendar-plan

# Configure
bash ~/.claude/skills/calendar-plan/setup.sh

# Dry-run
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --dry-run
```

`setup.sh` walks through:
- model / timezone / cron hour / Calendar Context path
- copies `planning-preferences.example.md` → `config/planning-preferences.md` (edit this)
- prompts for Notion token, GCal/Gmail OAuth paths, FS root → writes `config/mcp-config.json`
- chmod 600 on everything secret

### 3. Install the Codex target (optional, can run alongside)

```bash
bash codex/setup.sh
```

Resolves placeholders, writes `~/.codex/skills/calendar-plan/` and `~/.codex/automations/calendar-plan/`. MCP enablement on the Codex side is handled in `~/.codex/config.toml` (the Codex desktop app's OAuth flow populates tokens).

### 4. Run once manually

```bash
# Draft mode (no calendar writes)
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode draft

# Live mode (writes safe blocks to Google Calendar)
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode auto

# Plan a specific date
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --date 2026-05-19 --mode auto
```

### 5. Schedule (Claude target)

```bash
cp claude/launchd/com.user.calendar-plan.plist.example \
   ~/Library/LaunchAgents/com.user.calendar-plan.plist
# Edit the plist: replace <REPLACE_WITH_ABSOLUTE_PATH_TO_SKILL_DIR>
launchctl load ~/Library/LaunchAgents/com.user.calendar-plan.plist

# Verify
launchctl list | grep com.user.calendar-plan
launchctl start com.user.calendar-plan    # fire immediately for a test
```

Codex target schedules itself via the RRULE in `automation.toml` — no extra step.

### 6. Health check

```bash
bash ~/.claude/skills/calendar-plan/doctor.sh
bash codex/doctor.sh
```

## What's in each directory

```
calendar-plan-skill/
├── README.md                 (this file)
├── LICENSE
├── .gitignore                blocks real configs/tokens/memory/logs
├── docs/
│   ├── ARCHITECTURE.md       how the two targets share state
│   ├── INSTALLATION.md       longer install walkthrough
│   └── SETUP-MCPS.md         per-MCP credential setup (Notion, GCal, Gmail, FS)
├── prompts/
│   └── cron-prompt.md        single source of truth for the scheduled prompt
├── examples/
│   ├── planning-preferences.example.md
│   ├── memory.example.md
│   └── calendar-context.example.md
├── claude/                   Claude Code target
│   ├── SKILL.md              discoverability for /calendar-plan
│   ├── calendar-plan.sh      entrypoint
│   ├── setup.sh              wizard
│   ├── doctor.sh             health check
│   ├── scripts/              prep_context.py, apply_log.py
│   ├── config/
│   │   ├── mcp-config.example.json
│   │   └── settings.example.conf
│   └── launchd/
│       └── com.user.calendar-plan.plist.example
└── codex/                    Codex CLI target
    ├── SKILL.md
    ├── automation.example.toml
    ├── agents/openai.example.yaml
    ├── setup.sh
    └── doctor.sh
```

## Edge cases

- **One MCP unavailable.** The prompt says: continue with available sources; in `auto` mode, do NOT write blocks if the missing source could materially change the day. The planner emits a no-write + pause memory entry instead.
- **Cron fires while mac is asleep.** launchd will fire the job on next wake. The planner will see the calendar state at wake-time, not at the original fire-time. If you skipped a night, run manually the next morning to fill the gap.
- **Two targets run on the same evening.** Both Claude and Codex targets read/write the same Google Calendar. If both are active, expect duplicate planning blocks. Pick one for the cron; keep the other for ad-hoc use only.
- **Stale exam/deadline event on calendar.** The planner pauses rather than silently leaving conflicting events. Resolve manually.
- **Notion page renamed.** Both `TASK_SOURCE_NAME` (title search) and the planning-preferences.md fallback page ID (UUID lookup) should match. Update both if you rename.
- **Token rotated.** Edit `~/.claude/skills/calendar-plan/config/mcp-config.json` directly, or re-run `setup.sh`. No daemon restart needed — each run spawns fresh MCP processes.

## What not to do

- Do not commit `config/mcp-config.json`, `config/planning-preferences.md`, `config/settings.conf`, `memory/memory.md`, `automation.toml`, `agents/openai.yaml`, or anything under `logs/`. The repo's `.gitignore` blocks them by default — do not weaken it.
- Do not edit the Calendar Context page from the planner. The prompt forbids it for a reason: the user owns that page; the planner only reads it.
- Do not relax `--strict-mcp-config`. The whole point of this skill is that its MCPs do not leak into other Claude Code sessions.
- Do not delete existing calendar events from `auto` mode. The planner is additive only. Cleanup is a human task.
- Do not store secrets in `settings.conf` (it is sourced as bash; values are shell-escaped poorly). All secrets go in `mcp-config.json` only.

## See also

- `docs/ARCHITECTURE.md` — how the two targets share the prompt and what state lives where.
- `docs/SETUP-MCPS.md` — Notion / Google Calendar / Gmail / Filesystem MCP credential walkthroughs.
- `docs/INSTALLATION.md` — longer install walkthrough with troubleshooting.
