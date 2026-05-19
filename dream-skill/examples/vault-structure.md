# Vault Structure Examples

dream-skill works with **any directory of markdown files**. It doesn't need
Obsidian specifically, doesn't need a particular layout, and doesn't impose a
schema. You just point `config/vault-paths.toml` at your root and list which
subdirectories contain persona-relevant content.

This document shows three example layouts — minimal, categorized, and
power-user — so you can pick a starting point or adapt your existing vault.

---

## Example 1: Minimal

Single directory. Three files. Works out of the box.

### Directory tree

```
~/Documents/persona-vault/
└── persona/
    ├── role.md
    ├── projects.md
    └── goals.md
```

### Sample page (`persona/role.md`)

```markdown
---
title: Current Role
status: active
updated: 2026-05-13
last_verified: 2026-05-13
---

# Current Role

## Job
Software engineer at Example Corp. Started 2024-09. Working on the
billing platform team.

## Manager
Jane Doe.

## Schedule
Remote, ~9-5 ET. No standing meetings on Fridays.
```

### `config/vault-paths.toml`

```toml
vault_root = "/Users/you/Documents/persona-vault"
stale_days = 60

[[subdirs]]
name = "persona"
description = "core identity"
```

That's it. `./dream.sh` will work.

**When to use this layout:** you want to try dream-skill before committing to
a full vault structure. Three pages is enough to validate the loop.

---

## Example 2: Categorized

Multiple top-level directories by life domain. Good middle ground — enough
structure to keep things tidy, no overhead from formal indexing.

### Directory tree

```
~/Documents/Obsidian/
├── persona/
│   ├── role.md
│   ├── skills.md
│   ├── goals.md
│   └── relationships.md
├── projects/
│   ├── project-phoenix.md
│   ├── side-project-acme.md
│   └── archived/
│       └── old-project.md
├── fitness/
│   ├── current-program.md
│   ├── body-comp.md
│   └── nutrition.md
├── learning/
│   ├── books-2026.md
│   └── courses-current.md
└── notes/
    ├── 2026-05-13-meeting.md
    └── inbox/
```

### Sample frontmatter (`projects/project-phoenix.md`)

```markdown
---
title: Project Phoenix
status: active
updated: 2026-05-10
role: lead
stack: [python, postgres, kubernetes]
---

# Project Phoenix

## Goal
Replace the legacy billing pipeline by Q3 2026.

## Status
Migration of read paths is done. Write paths next sprint.

## Team
- Me (lead)
- Alice (backend)
- Bob (infra)
```

### Sample frontmatter (`projects/archived/old-project.md`)

```markdown
---
title: Old Project
status: archived
updated: 2025-12-01
archived_on: 2025-12-01
archived_reason: superseded by Phoenix
---

# Old Project
...
```

Note the `status: archived` — the dream cycle treats this as past-tense fact.
It won't re-flag old project mentions as "currently working on X."

### `config/vault-paths.toml`

```toml
vault_root = "/Users/you/Documents/Obsidian"
stale_days = 60

[[subdirs]]
name = "persona"
description = "identity, role, goals, relationships"
weight = "high"

[[subdirs]]
name = "projects"
description = "active and archived projects"
weight = "high"

[[subdirs]]
name = "fitness"
description = "training, body comp, nutrition"
weight = "medium"

[[subdirs]]
name = "learning"
description = "books, courses, study material"
weight = "low"

[[subdirs]]
name = "notes"
description = "meeting notes, atomic notes, inbox"
weight = "low"
```

**When to use this layout:** you already have an Obsidian habit, or you want
the dream cycle to differentiate domains (high-weight persona vs low-weight
notes). This is the recommended baseline for most users.

---

## Example 3: Power user

Categorized layout plus:

- Wiki index pages for navigation
- `status:` frontmatter discipline everywhere
- Dataview-friendly tagging
- An `inbox/` reserved for dream reports

### Directory tree

```
~/Documents/Obsidian/
├── wiki/
│   ├── index.md                         # top-level catalog
│   ├── persona-index.md
│   └── projects-index.md
├── persona/
│   ├── role.md
│   ├── skills.md
│   ├── goals.md
│   ├── schedule.md
│   ├── relationships.md
│   └── preferences.md
├── projects/
│   ├── _index.md
│   ├── project-phoenix/
│   │   ├── README.md
│   │   ├── decisions.md
│   │   └── retro.md
│   └── archived/
│       └── ...
├── fitness/
│   ├── _index.md
│   ├── programs/
│   ├── exercises/
│   └── nutrition/
├── learning/
│   ├── _index.md
│   ├── books/
│   ├── courses/
│   └── papers/
├── setup/                               # app configs, shortcuts, etc.
│   ├── _index.md
│   ├── shortcuts-canonical.md
│   └── editors/
├── notes/
│   ├── journal/
│   ├── meetings/
│   └── atomic/
└── inbox/
    └── dream-reports/                   # where dream-skill writes
```

### Sample page with full frontmatter (`persona/role.md`)

```markdown
---
title: Current Role
status: confirmed
updated: 2026-05-13
last_verified: 2026-05-13
tags: [persona, role, work]
employer: "Example Corp"
team: "billing-platform"
started: 2024-09-15
remote: true
manager: "Jane Doe"
---

# Current Role

## Job
Software engineer at Example Corp on the billing platform team.

## Stack
Python, Postgres, Kubernetes. Some Go for the gateway service.

## Cadence
Standups Tue/Thu only. No standing meetings on Fridays.

## North star
Promotion to senior by end of 2026.
```

The `status: confirmed` + recent `last_verified` combination signals to the
reconcile pass: "this is current and intentional — don't re-flag unless
there's clear new contradicting evidence."

### Sample wiki index (`wiki/index.md`)

```markdown
---
title: Vault Index
updated: 2026-05-13
---

# Vault Index

## Persona
- [Current Role](../persona/role.md)
- [Skills](../persona/skills.md)
- [Goals](../persona/goals.md)
- [Schedule](../persona/schedule.md)
- [Relationships](../persona/relationships.md)
- [Preferences](../persona/preferences.md)

## Projects
- [Active](../projects/_index.md)

## Fitness
- [Current program](../fitness/programs/_index.md)

## Learning
- [Books in progress](../learning/books/_index.md)
```

### `config/vault-paths.toml`

```toml
vault_root = "/Users/you/Documents/Obsidian"
stale_days = 60

# Long-form reference pages: extract only frontmatter, skip body.
# Keeps the LLM context manageable.
frontmatter_only = [
  "learning/books/**/*",
  "learning/papers/**/*",
  "fitness/exercises/**/*",
]

[[subdirs]]
name = "persona"
description = "core identity (highest priority)"
weight = "high"

[[subdirs]]
name = "projects"
description = "active and archived projects"
weight = "high"

[[subdirs]]
name = "fitness"
description = "training, body, nutrition"
weight = "medium"

[[subdirs]]
name = "learning"
description = "books, courses, papers"
weight = "low"

[[subdirs]]
name = "setup"
description = "tool configs and preferences"
weight = "low"

[[subdirs]]
name = "notes"
description = "journal, meetings, atomic notes"
weight = "low"

# Don't scan the wiki/ index pages (they're navigation only)
# Don't scan the inbox/dream-reports/ directory (that's the output destination)
```

**Tips for this layout:**

- The `frontmatter_only` globs save real money on cycles — a vault with 500
  long book notes can blow the token budget if every page is fully read.
- Use `_index.md` files within each category subdir for human navigation
  (Obsidian shows them well). The dream cycle just scans them like any
  other page.
- Reserve `inbox/dream-reports/` exclusively for dream-skill output. Don't
  put it inside one of the scanned subdirs, or reports start reconciling
  against themselves.

**When to use this layout:** you're invested in Obsidian, have a habit of
keeping `updated:` and `status:` current, and want the dream cycle to be
maximally precise. This is the layout that produces the cleanest reports.

---

## Pointing dream-skill at YOUR vault

Whatever layout you adopt, the recipe is the same:

1. **Set `vault_root`** in `config/vault-paths.toml` to your vault's
   absolute path.
2. **Add `[[subdirs]]` blocks** for each directory the cycle should scan.
   Anything not listed is invisible to dream-skill.
3. **Optionally tune `weight`** to bias the LLM's attention. `high` for core
   persona pages, `low` for noisy reference dirs.
4. **Optionally fill `frontmatter_only`** with glob patterns for very long
   reference content where you only want metadata extracted.

Run a dry cycle to confirm:

```bash
./dream.sh --dry-run
cat /tmp/dream-vault-$(date +%Y-%m-%d).md
```

You should see your pages listed with frontmatter and section headings.

---

## Recommended frontmatter conventions

dream-skill recognizes these frontmatter fields and uses them in
reconciliation:

| Field | Type | Meaning |
|---|---|---|
| `title` | string | Human-readable page title. Fallback: H1 or filename. |
| `status` | enum | `active` / `confirmed` / `archived` / `completed` / `needs_verification` / `draft`. Past-tense statuses won't be re-flagged. |
| `updated` | date | When the page content was last changed. Pages older than `stale_days` get flagged as stale candidates. |
| `last_verified` | date | When a human last confirmed this page is current. Stronger signal than `updated`. |
| `tags` | list | Free-form. The LLM uses these for grouping. |
| `archived_on` | date | When the page transitioned to archived. Combined with `status: archived` makes the LLM treat content as past-tense. |
| `archived_reason` | string | Why it was archived. Useful for contradiction resolution. |

You don't need any of these — dream-skill works with raw markdown. They just
help the reconciliation pass make more accurate decisions.
