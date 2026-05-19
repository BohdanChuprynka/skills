# Contributing

PRs welcome. The repo is small and the surface is intentionally limited — keep changes scoped to one concern per PR.

## What lives where

| You want to change… | Edit this file |
|---|---|
| The scheduled prompt (planning rules, source order, write rules) | [`prompts/cron-prompt.md`](prompts/cron-prompt.md) — **single source of truth for both runtimes** |
| Skill discoverability (slash-command description, when Claude should trigger it) | [`skills/calendar-plan/SKILL.md`](skills/calendar-plan/SKILL.md) frontmatter |
| Codex slash-command UX | [`codex/SKILL.md`](codex/SKILL.md) frontmatter + [`codex/agents/openai.example.yaml`](codex/agents/openai.example.yaml) |
| Claude entrypoint behavior (CLI flags, model defaults, prompt rendering) | [`skills/calendar-plan/calendar-plan.sh`](skills/calendar-plan/calendar-plan.sh) |
| MCP wiring on the Claude side | [`skills/calendar-plan/config/mcp-config.example.json`](skills/calendar-plan/config/mcp-config.example.json) + [`skills/calendar-plan/setup.sh`](skills/calendar-plan/setup.sh) |
| MCP wiring on the Codex side | [`docs/MCP-SETUP.md`](docs/MCP-SETUP.md) → "Codex side" |
| Settings the wizard prompts for | [`skills/calendar-plan/setup.sh`](skills/calendar-plan/setup.sh) + [`skills/calendar-plan/config/settings.example.conf`](skills/calendar-plan/config/settings.example.conf) |
| Memory format (how `apply_log.py` summarises a run) | [`skills/calendar-plan/scripts/apply_log.py`](skills/calendar-plan/scripts/apply_log.py) + [`examples/memory.example.md`](examples/memory.example.md) |
| Doctor checks | [`skills/calendar-plan/doctor.sh`](skills/calendar-plan/doctor.sh) (Claude) + [`codex/doctor.sh`](codex/doctor.sh) (Codex) |
| launchd plist (mac cron) | [`skills/calendar-plan/launchd/com.user.calendar-plan.plist.example`](skills/calendar-plan/launchd/com.user.calendar-plan.plist.example) |
| Codex cron RRULE / model / cwd | [`codex/automation.example.toml`](codex/automation.example.toml) |
| User-facing install steps | [`docs/INSTALL.md`](docs/INSTALL.md) |
| Top-level pitch / mental model / nav | [`README.md`](README.md) |

## Dev loop

```bash
# 1. Clone for development
git clone https://github.com/BohdanChuprynka/calendar-plan-skill.git ~/calendar-plan-skill-dev
cd ~/calendar-plan-skill-dev

# 2. Install the Claude target as a symlink (changes propagate)
ln -s "$PWD/skills/calendar-plan" ~/.claude/skills/calendar-plan
bash ~/.claude/skills/calendar-plan/setup.sh

# 3. Edit the prompt, scripts, or config
$EDITOR prompts/cron-prompt.md

# 4. Validate
bash ~/.claude/skills/calendar-plan/doctor.sh
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --dry-run
bash ~/.claude/skills/calendar-plan/calendar-plan.sh --mode draft

# 5. Sanity-check the Codex target if you touched the prompt
bash codex/setup.sh   # re-renders ~/.codex/automations/calendar-plan/automation.toml
bash codex/doctor.sh

# 6. Run the secret-leak audit
./scripts/audit-secrets.sh   # (or the inline grep loop from README — TBD: extract to script)

# 7. Commit
git add -p
git commit
```

## How to test a prompt change end-to-end without burning your real calendar

```bash
# Use draft mode + dry run for fast iteration (no calendar writes, no API call)
./calendar-plan.sh --dry-run | less

# Run with real LLM call but no writes:
./calendar-plan.sh --mode draft 2>&1 | tee /tmp/plan-test.log

# Run with writes against a SEPARATE test calendar:
# - Add a "Test" calendar in Google Calendar
# - Replace calendar IDs in a copy of planning-preferences.md with the test one
# - export CALENDAR_PLAN_PREFS_OVERRIDE=/tmp/test-prefs.md  (TBD: not yet supported)
```

For now, the safest test loop is: draft mode against your real calendar, sanity-check the proposal, manually apply the parts you want.

## Style notes

- **Prompt edits**: keep the imperative tone. The cron prompt is read by an LLM under time pressure; verbose conditionals don't help.
- **README edits**: mirror the dream-skill structure (Problem → What it does → How → Install → ...). Don't reorder sections without a reason.
- **Shell scripts**: `set -euo pipefail` at the top. Resolve paths with `cd ... && pwd` instead of relative manipulation. Use the `heading/ok/warn/fail/skip` helpers defined in setup.sh / doctor.sh.
- **Python scripts**: stdlib only. Anything `import`-ed must work on Python 3.10+.
- **Secrets**: never commit a real token, calendar ID, or absolute home path. The secret audit (in the commit hook / CI) blocks the merge.

## Two runtimes — keep them in sync

The hardest invariant: edits to `prompts/cron-prompt.md` must produce identical behavior on both Claude and Codex targets. Both runtimes consume the same file (the Codex side re-renders `automation.toml` from it via `codex/setup.sh`).

If you find yourself wanting runtime-specific prompt behavior, prefer environment-conditional logic INSIDE the prompt over duplicating the prompt body. If that's unwieldy, fork into `prompts/claude-prompt.md` and `prompts/codex-prompt.md` and update both entrypoints — but document why.

### Recommended install layout (auto-sync)

To keep both runtimes in sync with minimal effort, install via symlinks:

```bash
# Clone once
git clone https://github.com/BohdanChuprynka/calendar-plan-skill.git \
  ~/Documents/IT-Work/Projects/IT/skills/calendar-plan-skill
REPO=~/Documents/IT-Work/Projects/IT/skills/calendar-plan-skill

# Claude target: symlink the whole skill dir
ln -s "$REPO/skills/calendar-plan" ~/.claude/skills/calendar-plan

# Codex target: COPY the stable files (Codex doesn't follow symlinks for skill discovery)
cp "$REPO/codex/SKILL.md"                  ~/.codex/skills/calendar-plan/SKILL.md
cp "$REPO/codex/agents/openai.example.yaml" ~/.codex/skills/calendar-plan/agents/openai.yaml

# Single shared planning-preferences.md (canonical = Codex side; Claude symlinks to it)
ln -s ~/.codex/skills/calendar-plan/planning-preferences.md \
      ~/.claude/skills/calendar-plan/config/planning-preferences.md
```

### Local vs committed files (.env pattern)

Every user-customizable file follows the dotenv convention: a committed `*.example.*` template and a gitignored local copy. Edit the local copy; the example stays generic.

| Committed template (in repo) | Local file (gitignored) | Where the local file lives |
|---|---|---|
| `prompts/cron-prompt.example.md` | `prompts/cron-prompt.md` | repo dir (same folder as the example) |
| `examples/planning-preferences.example.md` | `planning-preferences.md` | `~/.codex/skills/calendar-plan/` (canonical; Claude side symlinks) |
| `examples/memory.example.md` | `memory.md` | `~/.codex/automations/calendar-plan/` (canonical; Claude side symlinks) |
| `examples/calendar-context.example.md` | `Calendar Context.md` | Your Obsidian vault (anywhere — path is in settings.conf) |
| `skills/calendar-plan/config/mcp-config.example.json` | `mcp-config.json` | `<repo>/skills/calendar-plan/config/` |
| `skills/calendar-plan/config/settings.example.conf` | `settings.conf` | `<repo>/skills/calendar-plan/config/` |
| `codex/automation.example.toml` | `automation.toml` | `~/.codex/automations/calendar-plan/` |

The local file is auto-bootstrapped from the example on first run for the prompt (`calendar-plan.sh` and `sync.sh` both auto-copy if missing). Other files are seeded by `setup.sh` / `codex/setup.sh`.

### Update workflow

What needs explicit re-sync vs what auto-propagates:

| You edited… | Claude target | Codex target |
|---|---|---|
| `skills/calendar-plan/SKILL.md` | Auto (symlinked) | N/A |
| `skills/calendar-plan/calendar-plan.sh` or scripts | Auto (symlinked) | N/A |
| `codex/SKILL.md` | N/A | **Run `bash sync.sh`** + restart Codex |
| `codex/agents/openai.example.yaml` | N/A | **Run `bash sync.sh`** + restart Codex |
| `planning-preferences.md` (local) | Auto (symlinked → one file) | Auto (symlinked → one file) |
| `memory.md` (local) | Auto (symlinked → one file) | Auto (symlinked → one file) |
| **`prompts/cron-prompt.md`** (local) | Auto (read fresh per run) | **Run `bash sync.sh`** |
| `prompts/cron-prompt.example.md` (template) | Touched only via local copy (see above) | Same |
| `codex/automation.example.toml` (RRULE, model) | N/A | Run `bash codex/setup.sh` (full re-render) |

So the **only sync command you need in day-to-day use is**:

```bash
bash sync.sh         # copies SKILL.md / openai.yaml AND re-renders automation.toml
```

Use `bash sync.sh --dry-run` to preview without writing.

**Restart Codex** after `sync.sh` if you edited `codex/SKILL.md` — Codex scans skills at process startup, not per-invocation.

For a full re-install (rare — only when you change Codex metadata like RRULE/model/cwd), use `bash codex/setup.sh`.

> **Why not symlink the Codex side too?** Codex's skill discovery looks for real files in `~/.codex/skills/<name>/SKILL.md`. Symlinks are silently skipped (verified — all working sibling skills are regular files). The Claude side is fine with symlinks; Codex is not.

### Disabling the Codex cron (manual-mode use)

To use both runtimes manually without either firing on a schedule:

```bash
# Set status to INACTIVE in ~/.codex/automations/calendar-plan/automation.toml
sed -i '' 's/^status = "ACTIVE"/status = "INACTIVE"/' \
  ~/.codex/automations/calendar-plan/automation.toml
```

Re-enable later by flipping back to `"ACTIVE"`. The skill stays invocable via `/calendar-plan` in Codex regardless of status.

## License

Contributions are licensed MIT (same as the project). By submitting a PR you agree to license your changes under MIT.
