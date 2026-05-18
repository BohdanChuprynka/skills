# Installation

Step-by-step install with troubleshooting. For the short version see the top-level `README.md`.

## Prereqs

- macOS (tested) or Linux (untested but should work for the Claude target)
- `claude` CLI on PATH — install at https://docs.claude.com/claude-code
- `node` + `npx` on PATH — `brew install node`
- `python3` (3.10+)
- For the Codex target: the `codex` CLI installed and run at least once (creates `~/.codex/`)
- For Google Calendar / Gmail: a Google Cloud project with OAuth credentials

## Step 1 — clone the repo

```bash
git clone git@github.com:<you>/calendar-plan-skill.git
cd calendar-plan-skill
```

## Step 2 — install the Claude target

### Option A: symlink (recommended)

```bash
ln -s "$PWD/claude" ~/.claude/skills/calendar-plan
```

Edits to the repo propagate to the skill. Pull updates with `git pull`.

### Option B: copy

```bash
cp -R claude ~/.claude/skills/calendar-plan
```

You'll need to re-copy on every repo update. Use only if you want to fork the skill locally.

### Configure

```bash
bash ~/.claude/skills/calendar-plan/setup.sh
```

The wizard asks for:
- model (default: `claude-sonnet-4-6`)
- timezone (default: `America/New_York`)
- cron hour (default: `22`)
- absolute path to your Calendar Context markdown
- Notion task-source page title
- Optional MCP credentials (Notion token, GCal/Gmail paths, FS root)

It writes (all chmod 600):
- `config/settings.conf`
- `config/planning-preferences.md` (copied from example — **edit this before first run**)
- `config/mcp-config.json`
- `memory/memory.md` (seeded)

### Verify

```bash
bash ~/.claude/skills/calendar-plan/doctor.sh
```

Should print `all checks pass.` Common failures:
- `mcp-config.json still contains <REPLACE_WITH...> placeholders` → re-run setup.sh and answer the prompts.
- `planning-preferences.md still contains placeholders` → edit `config/planning-preferences.md` and replace all `<...>` placeholders with real values.
- `mcp-config json INVALID JSON` → likely a stray quote when you pasted a token. Open the file, validate with `python3 -c "import json; json.load(open('config/mcp-config.json'))"`.

### Dry-run

```bash
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --dry-run
```

Prints the rendered prompt and the command that would run — no API call. Check that all `{{PLACEHOLDERS}}` are resolved.

### First live run (draft mode — no calendar writes)

```bash
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode draft
```

The planner will print a proposed plan and exit. Inspect for sanity. If it looks right, run in auto:

```bash
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode auto
```

Check the resulting blocks on your calendar and the appended memory entry at `~/.claude/skills/calendar-plan/memory/memory.md`.

## Step 3 — schedule the Claude target (launchd)

```bash
cp claude/launchd/com.user.calendar-plan.plist.example \
   ~/Library/LaunchAgents/com.user.calendar-plan.plist

# Edit the plist — replace <REPLACE_WITH_ABSOLUTE_PATH_TO_SKILL_DIR> with
# the absolute path to wherever you installed the skill (~/.claude/skills/calendar-plan)
$EDITOR ~/Library/LaunchAgents/com.user.calendar-plan.plist

# Load it
launchctl load ~/Library/LaunchAgents/com.user.calendar-plan.plist

# Verify
launchctl list | grep com.user.calendar-plan

# Fire it immediately for a test
launchctl start com.user.calendar-plan
# Check the log
tail -f ~/.claude/skills/calendar-plan/logs/launchd.out
```

### Troubleshoot launchd

- **Job loaded but never fires:** `StartCalendarInterval` skips if the mac is asleep at that minute. macOS does NOT replay missed launchd events for non-system jobs. Solution: leave the mac awake at the configured time, or use `pmset` to schedule a wake.
- **Job fires but `claude` not found:** PATH issue — confirm `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel) is in the plist's `EnvironmentVariables.PATH`.
- **No output in logs:** check `StandardOutPath` / `StandardErrorPath` in the plist resolve to a writable directory.

### Unload

```bash
launchctl unload ~/Library/LaunchAgents/com.user.calendar-plan.plist
```

## Step 4 — install the Codex target (optional)

> **WARNING:** Do not enable BOTH targets as cron jobs simultaneously — they'll write duplicate blocks. Pick one for the cron, use the other ad-hoc.

```bash
bash codex/setup.sh
```

The installer:
1. Copies `SKILL.md` and `agents/openai.yaml` to `~/.codex/skills/calendar-plan/`
2. Copies `planning-preferences.example.md` to `~/.codex/skills/calendar-plan/planning-preferences.md` if not present (edit it)
3. Asks for placeholders (Calendar Context path, task source name, TZ, cron hour, cwd, model, reasoning) and renders `~/.codex/automations/calendar-plan/automation.toml`
4. Seeds `~/.codex/automations/calendar-plan/memory.md`

### Verify

```bash
bash codex/doctor.sh
codex automations list           # should show "calendar-plan"
```

### MCP enablement on Codex side

Codex manages MCPs in `~/.codex/config.toml`. Enable Notion / Calendar / Gmail / Filesystem under `[mcp_servers]`. The Codex desktop app handles OAuth flows for hosted integrations. See `docs/SETUP-MCPS.md` → "Codex side".

## Step 5 — turn off the existing automation (if migrating)

If you previously had this skill running under one runtime and are switching, disable the old one so you don't get duplicate writes:

- **Codex → Claude switch:** edit `~/.codex/automations/calendar-plan/automation.toml`, set `status = "INACTIVE"`, or delete the file.
- **Claude → Codex switch:** `launchctl unload ~/Library/LaunchAgents/com.user.calendar-plan.plist` and either delete or move the plist out of `LaunchAgents/`.

## Updating

```bash
cd ~/calendar-plan-skill
git pull
```

If you symlinked the Claude target, changes propagate immediately. If you copied, re-copy:

```bash
cp -R claude/. ~/.claude/skills/calendar-plan/
```

For the Codex target, re-run the installer:

```bash
bash codex/setup.sh
```

(it skips overwriting `planning-preferences.md` and `memory.md` by default)

## Uninstalling

```bash
# Claude target
launchctl unload ~/Library/LaunchAgents/com.user.calendar-plan.plist 2>/dev/null
rm -i ~/Library/LaunchAgents/com.user.calendar-plan.plist
rm -rI ~/.claude/skills/calendar-plan

# Codex target
rm -rI ~/.codex/skills/calendar-plan
rm -rI ~/.codex/automations/calendar-plan
# (the cron auto-disappears when the automation.toml is gone)

# Repo (after exporting any memory you want to keep)
cd .. && rm -rI ~/calendar-plan-skill
```
