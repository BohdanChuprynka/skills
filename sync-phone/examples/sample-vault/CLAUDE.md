# Sample Vault — Career Knowledge Base

## What this is

A personal knowledge base capturing professional life: roles, skills, projects, career direction, learning. The LLM maintains all wiki pages.

This is an *example* vault shipped with sync-phone to demonstrate the required shape. Adapt to your own scope.

## Directory structure

```
wiki/             — markdown pages
wiki/index.md     — catalog of all pages
wiki/log.md       — chronological record of ingests and edits
CLAUDE.md         — this file
```

## Wiki page categories

- **Identity** — Bio, background, location, philosophy.
- **Skills** — Technical skill domains. One page per domain.
- **Experience** — Professional roles. One page per role.
- **Projects** — Personal and professional projects.
- **Career** — Direction, networking, applications, side hustles.
- **Learning** — Active learning paths, courses, podcasts, mentors.
- **Sources** — Summary pages for ingested raw sources (resumes, podcasts, etc.).

## Page format

```markdown
---
tags: [category]
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [list of source filenames]
---

# Page Title

Content. Use [[wikilinks]] for cross-references.
```

## Conventions

- Use `[[wikilinks]]` for cross-references between pages.
- Dates in ISO 8601 format (YYYY-MM-DD).
- One topic per page. Sub-topics get their own page if they're substantial.
- Tag in frontmatter for Dataview compatibility.

## Operations

### Ingest

1. Apply the bullet to the right wiki page (create if needed).
2. Update `wiki/index.md` if a new page was created.
3. Append an entry to `wiki/log.md`.

## Log format

```markdown
## [YYYY-MM-DD] action | Description
What was done, which pages were touched.
```
