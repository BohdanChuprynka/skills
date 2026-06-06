# Skills

> Personal monorepo of [Claude Code](https://docs.claude.com/claude-code) skills I use daily. Each subfolder is a self-contained skill that automates one piece of my workflow around Obsidian, voice capture, daily planning, and audio transcription.

For background on what skills are and how they work:
- [What are skills?](https://support.claude.com/en/articles/12512176-what-are-skills)
- [Using skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)
- [How to create custom skills](https://support.claude.com/en/articles/12512198-creating-custom-skills)
- [Anthropic's official skills repo](https://github.com/anthropics/skills)

## About this repository

Personal collection. Not an Anthropic project. The skills here automate the parts of my workflow that were getting expensive to do by hand. Shared in case the patterns save someone else a few hours of glue code.

Each skill is independent: install one without the others. All MIT licensed. All run entirely on your machine. No skill in this repo phones home, sells data, or requires a paid service beyond Claude Code itself.

## The skills

| Skill | What it does | Install path |
|---|---|---|
| [**dream-skill**](./dream-skill) | Auto-records every Claude Code session to your Obsidian vault on close. SessionEnd hook fires a headless `claude -p` that extracts persona-relevant facts (projects, decisions, deadlines), writes the confident ones add-only to your vault, queues the uncertain ones for manual review. No `/sync` to remember. Claude Code only. | Plugin (auto-installs hooks) |
| [**clean-wiki**](./clean-wiki) | Monthly Obsidian vault cleanup. Sub-agents scan your vaults for stale facts, contradictions, broken wikilinks, orphans, frontmatter drift. You swipe approve/reject in a local web UI. Claude applies approved changes with an undo log. | Symlink |
| [**calendar-plan-skill**](./calendar-plan-skill) | Dual-target (Claude Code + Codex CLI) daily calendar planner. Drafts tomorrow's calendar from your Obsidian vault, Google Calendar, Gmail, and a local context note. Two modes: `/calendar-plan` (draft, confirm, apply) and `/calendar-plan auto` (apply safe blocks directly). Ships with a launchd job for evening auto-runs. | Symlink |
| [**sync-phone**](./sync-phone) | iPhone voice-dictation pipeline. Drains an iCloud-shared dictation sink, summarizes the raw transcripts, routes bullets into the right Obsidian vault, archives the source, clears the inbox. Pairs with an iPhone Shortcut for the capture side. | Symlink |
| [**transcribe-audio**](./transcribe-audio) | Audio file to clean transcript to optional LLM summary to optional Obsidian note. OpenAI Whisper backend. Auto-chunks files past the 25 MB API limit, primes the recognizer with custom technical vocabulary, ships three summary styles. Strong on Ukrainian, Russian, English, and code-switching. | Symlink |
| [**voice-check**](./voice-check) | Audit and rewrite drafts so they sound like you, not generic AI. Builds a measured voice profile from your own writing, scores any draft 0-100 against it, and flags AI tells, corporate words, em dashes, leftover filler, and sentence-length drift — each with a fix. Offline, zero-dependency, with an ROC-AUC proof that it separates your writing from AI. Claude Code + Codex CLI. | `./setup.sh` |

## Install

Two install paths depending on the skill.

### Plugin install (for dream-skill)

Auto-installs hooks into your `~/.claude/settings.json` on install. No manual config edits.

```bash
/plugin marketplace add BohdanChuprynka/skills
/plugin install dream-skill@dream-skill-marketplace
```

Then create the per-skill config file. See [dream-skill/README.md](./dream-skill/README.md) for the specifics.

### Symlink install (for everything else)

For clean-wiki, calendar-plan-skill, sync-phone, transcribe-audio:

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
| dream-skill | ✓ | not yet | ✓ | ✓ | WSL2 |
| clean-wiki | ✓ | not yet | ✓ | ✓ | WSL2 |
| calendar-plan-skill | ✓ | ✓ | ✓ | ✓ | WSL2 |
| sync-phone | ✓ | ✓ | ✓ | ✓ | WSL2 |
| transcribe-audio | ✓ | ✓ | ✓ | ✓ | WSL2 |

All bash + Python. Windows users need WSL2 or Git Bash.

## Privacy

These skills work on personal data: calendars, dictation, Obsidian vault content. The repo is built so nothing personal ships in commits:

- Per-skill `.gitignore` excludes runtime data, real config paths, logs.
- All committed examples use generic placeholders.
- Real config lives in `config/*.toml` (gitignored). Every skill ships a sanitized `*.example.toml` template.
- Vault content, calendar events, dictation text, etc. never leave your machine.

If you fork this and push changes, run `git status --ignored` before the first push to verify nothing personal slipped through.

## License

All skills in this repo are MIT licensed. See [LICENSE](./LICENSE).

## Why this is public

I keep these here so I can pull them onto fresh machines with one `git clone`. Also because the patterns might save someone else a few hours of glue code. If you build something on top of one of these, I'd love to see it. Open an issue or PR.
