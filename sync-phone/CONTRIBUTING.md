# Contributing to sync-phone

Issues and PRs welcome. Open an issue first for non-trivial changes so we can agree on direction before you spend the time.

## Quick orientation

```
sync-phone/
├── skills/sync-phone/SKILL.md     # the skill itself — what it does, the workflow
├── commands/sync-phone.md         # the /sync-phone slash command
├── .claude-plugin/                # plugin distribution metadata
│   ├── plugin.json
│   └── marketplace.json
├── docs/                          # user-facing setup walkthroughs
│   ├── SHORTCUT-SETUP.md
│   └── VAULT-SETUP.md
├── examples/                      # working demo files
│   ├── sample-vault/              # minimal vault demonstrating the shape
│   └── sample-run.md              # end-to-end walkthrough
├── README.md
├── CHANGELOG.md
├── LICENSE
└── .gitignore
```

## What to edit (sources of truth)

| I want to change... | Edit this file |
|---|---|
| What the skill does, when it triggers, the workflow steps | `skills/sync-phone/SKILL.md` |
| The slash-command entry point | `commands/sync-phone.md` |
| Plugin name, version, keywords | `.claude-plugin/plugin.json` |
| Marketplace listing | `.claude-plugin/marketplace.json` |
| iPhone Shortcut walkthrough | `docs/SHORTCUT-SETUP.md` |
| Vault setup requirements | `docs/VAULT-SETUP.md` |
| The README story / structure | `README.md` |
| Example vault content | `examples/sample-vault/` |
| End-to-end walkthrough | `examples/sample-run.md` |
| Changelog entries | `CHANGELOG.md` |

## Style

- No em-dashes. Periods, commas, colons, parens carry the same load and read more like writing than punctuation jewelry.
- Natural voice. Direct, not corporate. If you wouldn't say it out loud, rewrite it.
- Explain *why* before *how*. The why is what makes the doc useful when the how changes.

## Testing

There's no automated test suite. The skill operates against real Obsidian files. To test changes:

1. Set up the example vault under `~/Documents/Obsidian/test-vault/`.
2. Drop a synthetic `iphone-raw.md` into your capture directory.
3. Run `/sync-phone` in Claude Code.
4. Inspect the vault edits, the archive entry, and the cleared inbox.

If you find yourself wishing for unit tests, open an issue — we can talk about adding a fixture-driven test harness.
