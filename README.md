# Skills

> Personal monorepo of [Claude Code](https://docs.claude.com/claude-code) skills I use daily. Each folder is a self-contained skill — its own `SKILL.md`, its own README, its own install steps. Drop them into `~/.claude/skills/` and Claude picks them up.

For background on what skills are and how they work:
- [What are skills?](https://support.claude.com/en/articles/12512176-what-are-skills)
- [Using skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)
- [How to create custom skills](https://support.claude.com/en/articles/12512198-creating-custom-skills)
- [Anthropic's official skills repo](https://github.com/anthropics/skills)

## About this repository

This is a personal collection — not an Anthropic project. The skills here automate parts of my workflow around Obsidian, voice capture, and daily planning. They're shared in case the patterns are useful, and so anyone reading them can fork and adapt.

Each skill is independent: you can install one without the others. They're all MIT licensed and run entirely on your machine — no skill in this repo phones home, sells data, or requires a paid service beyond Claude Code itself.

## The skills

| Skill | What it does |
|--|--|
| [**clean-wiki**](./clean-wiki) | Monthly Obsidian vault cleanup. Sub-agents scan your vaults for stale facts, contradictions, broken wikilinks, orphans, frontmatter drift. You swipe approve/reject in a local web UI. Claude applies the approved changes with an undo log. |
| [**calendar-plan-skill**](./calendar-plan-skill) | Dual-target (Claude Code + Codex CLI) daily calendar planner. Drafts tomorrow's calendar from your Obsidian vault, Google Calendar, Gmail, and a local context note. Two modes — `/calendar-plan` (draft → confirm) and `/calendar-plan auto` (apply safe blocks directly). Includes a launchd job for evening auto-runs. |
| [**sync-phone**](./sync-phone) | iPhone voice-dictation pipeline. Drains an iCloud-shared dictation sink, summarizes the raw audio transcripts, routes the bullets into the right Obsidian vault, archives the source, and clears the inbox. Pairs with an iPhone Shortcut for the capture side. |
| [**dream-skill**](./dream-skill) | Wiki reconciliation. Audits your Obsidian vaults against recent Claude Code / Codex CLI sessions and connected MCP sources (Notion, Calendar, Gmail) — flags stale, missing, and contradicted facts for review before applying. |

## Install

Pick a skill, follow its README. The general pattern is:

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/<skill-name>
# read the skill's README for setup (config files, deps, MCP servers, etc.)
ln -s "$(pwd)/skills/<skill-name>" ~/.claude/skills/<skill-name>
```

Then inside Claude Code:

```
/<skill-name>
```

Each skill includes its own prerequisites, config files, and optional dependencies. See per-skill READMEs for the specifics.

## Skill structure

Every skill in this repo follows the same shape:

```
<skill-name>/
├── README.md                       ← user-facing intro, install, screenshots
├── docs/                           ← optional design notes, screenshots, diagrams
└── skills/<skill-name>/
    ├── SKILL.md                    ← the runtime instructions Claude reads
    ├── config/                     ← per-user config (gitignored if it contains paths/secrets)
    ├── scripts/                    ← supporting Python / shell helpers
    └── web/                        ← optional local UI (some skills)
```

The double `skills/<skill-name>/` path is the convention Claude Code uses to discover skills inside a monorepo. The outer folder is the GitHub-facing project; the inner `skills/<skill-name>/SKILL.md` is what gets symlinked into `~/.claude/skills/`.

## Privacy

These skills work on personal data — calendars, dictation, Obsidian vault content. The repo is built so nothing personal ships in commits:

- Per-skill `.gitignore` excludes runtime data, real config paths, logs.
- All committed examples use generic placeholders.
- Real config lives in `config/*.toml` (gitignored) — every skill ships a sanitized `*.example.toml` template.
- Vault content, calendar events, dictation text, etc. never leave your machine.

If you fork this and push changes, run `git status --ignored` before the first push to verify nothing personal slipped through.

## License

All skills in this repo are MIT licensed. See [LICENSE](./LICENSE).

## Why this is public

I keep these skills here partly so I can pull them onto fresh machines with one `git clone`, partly because the patterns might save someone else a few hours of glue code. If you build something on top of one of these, I'd love to see it — open an issue or PR.
