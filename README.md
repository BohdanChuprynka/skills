# Skills

> Personal monorepo of Claude Code and Codex skills I use daily. Each subfolder is a self-contained skill that automates one piece of my workflow around Obsidian, voice capture, daily planning, and audio transcription.

For background on what skills are and how they work:
- [What are skills?](https://support.claude.com/en/articles/12512176-what-are-skills)
- [Using skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)
- [How to create custom skills](https://support.claude.com/en/articles/12512198-creating-custom-skills)
- [Anthropic's official skills repo](https://github.com/anthropics/skills)

## About this repository

Personal collection. Not an Anthropic project. The skills here automate the parts of my workflow that were getting expensive to do by hand. Shared in case the patterns save someone else a few hours of glue code.

Each skill is independent: install one without the others. All MIT licensed. Runtime files stay local and no skill in this repo phones home or sells data. Skills that use Claude Code, Codex, Whisper, or connected services may still send task context to the active provider as part of the work.

## The skills

| Skill | What it does | Install path |
|---|---|---|
| [**dream-skill**](./dream-skill) | On-demand batch sync for Claude Code and Codex transcripts. Sweeps recent chats, extracts durable persona/project facts, routes and reconciles them against Obsidian vault pages, queues uncertain/destructive changes for review, writes receipts, and tracks source-specific markers. | `./setup.sh` or Claude plugin |
| [**clean-wiki**](./clean-wiki) | Monthly Obsidian vault cleanup. Claude Code or Codex scans your vaults for stale facts, contradictions, broken wikilinks, index drift, orphans, and frontmatter drift. You swipe approve/reject in a local web UI. The agent applies approved changes with an undo log. | `./setup.sh` |
| [**routing-mode**](./routing-mode) | Claude Code workflow that routes planning and review to Claude, gates the plan through a zero-context audit, delegates implementation to the Codex CLI, then brings the diff back for verification. | Claude plugin or symlink |
| [**calendar-plan-skill**](./calendar-plan-skill) | Dual-target (Claude Code + Codex CLI) daily calendar planner. Drafts tomorrow's calendar from your Obsidian vault, Google Calendar, Gmail, and a local context note. Two modes: `/calendar-plan` (draft, confirm, apply) and `/calendar-plan auto` (apply safe blocks directly). Ships with a launchd job for evening auto-runs. | Symlink |
| [**sync-phone**](./sync-phone) | iPhone voice-dictation pipeline. Drains an iCloud-shared dictation sink, summarizes the raw transcripts, routes bullets into the right Obsidian vault, archives the source, clears the inbox. Pairs with an iPhone Shortcut for the capture side. | Symlink |
| [**transcribe-audio**](./transcribe-audio) | Audio file to clean transcript to optional LLM summary to optional Obsidian note. OpenAI Whisper backend. Auto-chunks files past the 25 MB API limit, primes the recognizer with custom technical vocabulary, ships three summary styles. Strong on Ukrainian, Russian, English, and code-switching. | Symlink |
| [**voice-check**](./voice-check) | Audit and rewrite drafts so they sound like you, not generic AI. Builds a measured voice profile from your own writing, scores any draft 0-100 against it, and flags AI tells, corporate words, em dashes, leftover filler, and sentence-length drift — each with a fix. Offline, zero-dependency, with an ROC-AUC proof that it separates your writing from AI. Claude Code + Codex CLI. | `./setup.sh` |
| [**session-continue**](./session-continue) | Import a Claude Code, Codex, or other `continues`-supported coding session into the current agent thread by source and session id. Supports `$session-continue from claude ...` in Codex and `/session-continue from codex ...` in Claude Code. | `./setup.sh` |

## Install

Install path depends on the skill.

### Claude plugin install

For plugin-packaged skills:

```bash
/plugin marketplace add BohdanChuprynka/skills
/plugin install dream-skill@skills
# or
/plugin install routing-mode@skills
```

For a local dream-skill install covering Claude + Codex:

```bash
cd dream-skill
bash setup.sh
```

Then create or edit the per-skill config file. See [dream-skill/README.md](./dream-skill/README.md) for the specifics.

### Symlink install

For calendar-plan-skill, routing-mode, sync-phone, transcribe-audio:

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills
ln -s "$(pwd)/<skill-name>/skills/<skill-name>" ~/.claude/skills/<skill-name>
```

Then inside Claude Code:

```
/<skill-name>
```

Each skill's README documents its own prerequisites (jq, Python, MCP servers, OAuth tokens, etc.) and config files.

### Setup-script install

For dual-runtime skills that need to copy files into Codex or prepare local runtime dependencies, run their installer:

```bash
cd <skill-name>
./setup.sh
```

Currently: `dream-skill`, `clean-wiki`, `voice-check`, `session-continue`.

## Skill structure

Every skill in this repo follows the same shape:

```
<skill-name>/
├── README.md                       # user-facing intro, install, screenshots
├── docs/                           # optional design notes, diagrams (some skills)
├── hooks/                          # plugin hooks.json (plugin-installed skills only)
├── .claude-plugin/                 # plugin manifest (plugin-installed skills only)
└── skills/<skill-name>/
    ├── SKILL.md                    # runtime instructions Claude reads
    ├── config/                     # per-user config (gitignored if it contains paths/secrets)
    ├── scripts/                    # supporting Python / shell helpers
    └── web/                        # optional local UI (some skills)
```

The double `skills/<skill-name>/` path is the convention Claude Code uses to discover skills inside a monorepo. Outer folder is the GitHub-facing project. Inner `skills/<skill-name>/SKILL.md` is what gets symlinked into `~/.claude/skills/` (or auto-loaded by `/plugin install`).

## Compatibility

| Skill | Claude Code | Codex CLI | macOS | Linux | Windows |
|---|---|---|---|---|---|
| dream-skill | ✓ | ✓ | ✓ | ✓ | WSL2 |
| clean-wiki | ✓ | ✓ | ✓ | ✓ | WSL2 |
| routing-mode | ✓ | Uses Codex CLI | ✓ | ✓ | WSL2 |
| calendar-plan-skill | ✓ | ✓ | ✓ | ✓ | WSL2 |
| sync-phone | ✓ | ✓ | ✓ | ✓ | WSL2 |
| transcribe-audio | ✓ | ✓ | ✓ | ✓ | WSL2 |
| voice-check | ✓ | ✓ | ✓ | ✓ | WSL2 |
| session-continue | ✓ | ✓ | ✓ | ✓ | WSL2 |

All bash + Python. Windows users need WSL2 or Git Bash.

## Privacy

These skills work on personal data: calendars, dictation, Obsidian vault content. The repo is built so nothing personal ships in commits:

- Per-skill `.gitignore` excludes runtime data, real config paths, logs.
- All committed examples use generic placeholders.
- Real config lives in `config/*.toml` (gitignored). Every skill ships a sanitized `*.example.toml` template.
- Runtime data is local and gitignored. The active model/provider may still receive task context for skills that ask an agent to read private content or call an external API.

If you fork this and push changes, run `git status --ignored` before the first push to verify nothing personal slipped through.

## License

All skills in this repo are MIT licensed. See [LICENSE](./LICENSE).

## Why this is public

I keep these here so I can pull them onto fresh machines with one `git clone`. Also because the patterns might save someone else a few hours of glue code. If you build something on top of one of these, I'd love to see it. Open an issue or PR.
