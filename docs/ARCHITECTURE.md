# Architecture

How the two targets share state and stay in sync.

## One prompt, two runtimes

```
                    prompts/cron-prompt.md
                    (single source of truth)
                              │
              ┌───────────────┴────────────────┐
              ▼                                ▼
    claude/scripts/prep_context.py      codex/setup.sh
    (renders at runtime, per call)      (renders at install, once)
              │                                │
              ▼                                ▼
    /tmp/calendar-plan-prompt.*.md     ~/.codex/automations/calendar-plan/automation.toml
              │                                │
              ▼                                ▼
       claude --mcp-config X           codex (cron-fired)
       --strict-mcp-config             with [mcp_servers] in ~/.codex/config.toml
              │                                │
              └────────────┬───────────────────┘
                           ▼
          Google Calendar / Notion / Gmail / Filesystem
```

## State ownership

| State | Owned by | Why |
|---|---|---|
| Prompt body | repo (`prompts/cron-prompt.md`) | One source of truth. Edit once, both runtimes pick up next run. |
| Planning preferences | repo example + user config (`<install>/config/planning-preferences.md`) | Sanitized template in repo; real file lives next to the runtime that runs the cron. |
| MCP credentials (Claude) | `~/.claude/skills/calendar-plan/config/mcp-config.json` (chmod 600, gitignored) | Per-skill isolation via `--strict-mcp-config`. |
| MCP credentials (Codex) | `~/.codex/config.toml` `[mcp_servers]` blocks | Codex manages MCPs globally; the desktop app handles OAuth. |
| Run memory | Per-target: `<install>/memory/memory.md` | Memory is append-only; each runtime keeps its own log. Sharing would risk concurrent writes. |
| Calendar Context | User's Obsidian vault | Outside the skill. The skill reads, never writes. |
| Calendar writes | Google Calendar | Both runtimes write here. **Pick one for the cron.** |

## The `--strict-mcp-config` guarantee

This is the load-bearing security/cost property of the Claude target.

When you run `claude --mcp-config <file> --strict-mcp-config <prompt>`:
- The Claude process spawns ONLY the MCP servers listed in that file (npx subprocesses)
- Your other configured MCPs (`~/.claude.json` `mcpServers`, project `.mcp.json`, plugin MCPs) are **not loaded**
- Tokens in this file's `env` blocks are scoped to the subprocess; they never enter your daily Claude Code sessions

This means:
- The Notion bearer in `mcp-config.json` only flows to the Notion MCP subprocess spawned for THIS run
- Your daily Claude Code conversations have no Notion/Calendar/Gmail tools loaded — so no accidental token use, no context bloat, no rate-limit pollution

## Pipeline (Claude target)

```
1. calendar-plan.sh
   ├─ load config/settings.conf        (model, TZ, cron hour, paths)
   ├─ resolve --date (default: tomorrow in TZ)
   └─ ensure memory/memory.md exists

2. scripts/prep_context.py
   ├─ read prompts/cron-prompt.md
   ├─ substitute {{PLACEHOLDERS}}      (paths, target_date, mode, TZ)
   └─ write /tmp/calendar-plan-prompt.*.md

3. claude --mcp-config config/mcp-config.json --strict-mcp-config
          --model <MODEL>
          --add-dir <dirname of CALENDAR_CONTEXT>
          -p "@/tmp/calendar-plan-prompt.*.md"
   ├─ Claude reads the prompt and all referenced files
   ├─ MCP subprocesses spawn for the duration: notion, google-calendar, gmail, filesystem-vault
   ├─ tool calls happen (read Notion page, read calendar, read Gmail)
   ├─ in auto mode: write calendar blocks via google-calendar MCP
   └─ stdout tee'd to logs/run-<ISO>.log

4. scripts/apply_log.py
   ├─ parse the log for created/changed/pause verbs
   ├─ extract connector_status hints
   └─ append one block to memory/memory.md
```

## Pipeline (Codex target)

```
1. Codex scheduler fires on RRULE       (runs even if Codex app is closed,
                                         but the Codex daemon must be present)

2. Codex spawns a worktree-isolated     (execution_environment = "worktree")
   process at the configured cwd

3. The process reads:
   ├─ prompt (baked into automation.toml at install time)
   ├─ ~/.codex/skills/calendar-plan/planning-preferences.md
   ├─ ~/.codex/automations/calendar-plan/memory.md
   └─ Calendar Context (path in prompt)

4. The Codex model uses MCPs declared in ~/.codex/config.toml,
   subject to per-server enabled flags

5. Same write rules as the Claude target

6. Codex appends to memory.md per the prompt's "After writing" section
```

## Comparison

| Property | Claude target | Codex target |
|---|---|---|
| Scheduler | launchd | Codex internal RRULE |
| Survives app being closed | Yes | Only if Codex daemon present |
| MCP isolation | `--strict-mcp-config` per run | Global `[mcp_servers]` config |
| Token storage | `mcp-config.json` chmod 600 | OAuth via Codex desktop app |
| Model | Anthropic Claude (Sonnet 4.6 / Opus 4.7) | OpenAI gpt-5.5 (or whatever the user configures) |
| Debug iteration | Edit `prompts/cron-prompt.md`, re-run `calendar-plan.sh --dry-run` | Edit `automation.toml`, re-run `codex automations test calendar-plan` |
| Failure visibility | `logs/run-*.log` per run | Codex's own audit log |
| Cost | Anthropic API token billing | OpenAI / Codex billing |

## Why support both

The user already had a Codex automation. Building the Claude target alongside lets them:
1. **A/B compare planner quality** for a week or two — same prompt, different models.
2. **Choose per signal** — Claude when they want isolation + opus-tier reasoning; Codex when they want gpt-5.5's reasoning effort knob.
3. **Failover** — if one stack breaks (rate limit, API outage, model regression), the other still runs.

Long-term, pick one for the cron and demote the other to ad-hoc. Running both as cron schedulers writes duplicate blocks.

## Memory is append-only

Both targets append a structured block to their own `memory.md` per run. The planner reads memory at the start of each run as durable context — past observations, recurring corrections, connector failure patterns.

The skill explicitly prohibits compaction unless the user asks. Reason: memory is the only place run-to-run learning persists. Compacting silently throws away preference signal.

## Calendar Context is read-only from the skill

The Obsidian Calendar Context page lives outside the repo. The skill reads it via filesystem MCP (Claude) or directly via Codex's filesystem access. The prompt forbids writes to that page.

To capture new dated context for the planner, write to Calendar Context manually (or via your own ingestion pipeline like `sync-phone`). The planner is downstream of that page, not upstream.
