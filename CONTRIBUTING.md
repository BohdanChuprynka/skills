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

## License

Contributions are licensed MIT (same as the project). By submitting a PR you agree to license your changes under MIT.
