# Vault setup

sync-phone routes dictation into Obsidian vaults that follow the **LLM-curated wiki** pattern: one parent folder, one subfolder per vault, each subfolder has a `CLAUDE.md` that tells the LLM how to maintain it.

If you don't have vaults like this yet, this doc is the 5-minute starter. If you do, just confirm yours match the assumptions.

## Required shape

```
<VAULTS_DIR>/
├── <vault-1>/
│   ├── CLAUDE.md          # required — schema for this vault
│   └── wiki/
│       ├── index.md       # catalog of all pages, organized by category
│       └── <pages>.md     # actual content
├── <vault-2>/
│   ├── CLAUDE.md
│   └── wiki/
│       ├── index.md
│       └── <pages>.md
└── ...
```

The skill discovers vaults at runtime by listing `VAULTS_DIR` and picking up every directory that contains a `CLAUDE.md`. Anything without `CLAUDE.md` is ignored (so loose files in `VAULTS_DIR` or non-vault folders don't break anything).

## Minimum `CLAUDE.md` template

Each vault's `CLAUDE.md` is the LLM's user manual for that vault. The richer it is, the better the routing. Minimum viable version:

```markdown
# <Vault Name>

## What this is

A personal knowledge base about <scope>. The LLM maintains all wiki pages.

## Directory structure

\`\`\`
wiki/             — markdown pages
wiki/index.md     — catalog of all pages
wiki/log.md       — chronological record of ingests and edits
CLAUDE.md         — this file
\`\`\`

## Wiki page categories

- **<Category 1>** — short description of what kind of pages live here
- **<Category 2>** — ...

## Page format

Every wiki page uses this structure:

\`\`\`markdown
---
tags: [category]
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [list of source files that informed this page]
---

# Page Title

Content. Use [[wikilinks]] for cross-references.
\`\`\`

## Conventions

- Use [[wikilinks]] for cross-references.
- Dates in ISO 8601 (YYYY-MM-DD).
- Keep pages focused — one topic per page.

## Operations

### Ingest

1. Apply the bullet to the right wiki page (create new page if needed).
2. Update `wiki/index.md` if a new page was created.
3. Append an entry to `wiki/log.md`.

## Log format

\`\`\`markdown
## [YYYY-MM-DD] action | Description
What was done, which pages were touched.
\`\`\`
```

That's enough for the skill to route bullets cleanly. Once you have a few pages in a vault, the LLM can also use existing pages as examples of your voice and formatting preferences.

## `wiki/index.md` template

A flat catalog grouped by category:

```markdown
---
tags: [index]
updated: YYYY-MM-DD
---

# Wiki Index

## <Category 1>
- [[Page Name]] — one-line description
- [[Another Page]] — ...

## <Category 2>
- [[Page Name]] — ...
```

The skill reads this before deciding whether to update an existing page or create a new one. Keep it current — the skill will append entries for new pages it creates, but it can't fix entries for pages that were renamed manually.

## Example vault

A minimal working vault that demonstrates the pattern lives at [`examples/sample-vault/`](../examples/sample-vault/). Use it as a starting point — copy the `CLAUDE.md`, edit the scope, replace the categories with whatever you actually want to track.

## Global routing hint (optional)

If you have a `~/.claude/CLAUDE.md` at the top of your Claude Code config, you can add a "When to consult a vault" table that lists each vault and the topics it owns. The skill treats that as the primary routing cheat sheet when present. It looks like:

```markdown
## Active Vaults

| Domain | Path | When to consult |
|--------|------|-----------------|
| Gym | ~/Documents/Obsidian/gym | Workouts, exercises, body comp |
| Career | ~/Documents/Obsidian/career | Roles, skills, applications, networking |
| Projects | ~/Documents/Obsidian/projects | Specific codebases, architecture, goals |
```

Optional but recommended once you have more than two vaults — it removes ambiguity when a bullet could fit multiple places.
