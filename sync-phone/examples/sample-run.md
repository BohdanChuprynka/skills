# Sample run

A walkthrough of one full `/sync-phone` invocation against a sample inbox. Shows the raw input, the cleaned `ingest.md`, the vault edits that result, and the archive entry.

This is a synthetic example — names, dates, and content are fabricated to demonstrate the flow.

## Setup

Two example vaults under `~/Documents/Obsidian/`:

```
~/Documents/Obsidian/
├── career/                 (see examples/sample-vault/ in this repo)
│   ├── CLAUDE.md
│   └── wiki/
│       ├── index.md
│       ├── log.md
│       ├── Bio.md
│       ├── Career Direction.md
│       └── Active Learning.md
└── gym/
    ├── CLAUDE.md
    └── wiki/
        ├── index.md
        ├── log.md
        └── ...
```

## Step 1 — Input: `iphone-raw.md`

After a day of dictation:

```
## 2026-05-16 08:14
So I just ran a 5k this morning, felt good, ran it in like 24 minutes
which is faster than last week. The thing I noticed is my breathing got
ragged around the 3k mark. Need to work on aerobic base.

## 2026-05-16 12:30
hey um testing

## 2026-05-16 17:42
Listening to the Lenny podcast with the founder of Linear and he said
something interesting. The thing about product is that taste compounds.
Every small decision you make about how the product feels adds up over
years. He compared it to how a chef tastes the food at every step.
That's the insight I want to remember.

## 2026-05-16 19:05
Got a reply from the recruiter at that ML startup. They want to do a
quick screen on Wednesday at 2pm. Need to prep.
```

Four entries: one workout note, one misfire, one podcast takeaway, one career action.

## Step 2 — User runs the skill

In Claude Code:

```
/sync-phone
```

## Step 3 — Skill writes `ingest.md`

```markdown
# ingest.md — 2026-05-16 21:00 batch

Source: iphone-raw.md, 4 raw entries (1 misfire dropped, 3 substantive kept).

## gym

- [new: Run 2026-05-16 - 5k Morning] Morning 5k completed in ~24:00, faster than the prior week. Notable observation: breathing got ragged around the 3k mark. Personal takeaway: aerobic base needs work — current pace exceeds aerobic capacity at the 3k point.
- [log.md] Append `[2026-05-17] ingest | iPhone voice capture 2026-05-16 — morning 5k + aerobic base observation`.

## career

- [new: Lenny Podcast - Linear Founder] Create source page for Lenny podcast episode with the Linear founder. Key takeaway: product taste compounds. Every small decision about how the product feels accumulates over years. Analogy: a chef tasting food at every step — quality emerges from continuous micro-judgment, not occasional big calls.
- [Career Direction] Under Strategy, capture follow-up: recruiter from ML startup replied, screening call scheduled Wednesday 2pm — prep needed.
- [Active Learning] Add Lenny podcast to Currently Learning with link to [[Lenny Podcast - Linear Founder]].
- [log.md] Append `[2026-05-17] ingest | iPhone voice capture 2026-05-16 — Lenny podcast + recruiter callback`.

## unrouted

(none)

## dropped (noise / misfires)

- 1× misfire 2026-05-16 12:30 ("hey um testing")
```

## Step 4 — Skill applies edits to vaults

The skill creates two new pages and updates the existing ones:

**Created**: `gym/wiki/Run 2026-05-16 - 5k Morning.md`

```markdown
---
tags: [run]
created: 2026-05-16
updated: 2026-05-17
sources: [iphone-capture-2026-05-16]
---

# Run 2026-05-16 — 5k Morning

Solo morning 5k, completed in ~24:00. Faster than the prior week.

## Observation

Breathing got ragged around the 3k mark. Current pace exceeds aerobic capacity at that point. Aerobic base is the limiter.

## Action

Add an aerobic base block to the next training week — easy-pace volume below the breathing-ragged threshold.
```

**Created**: `career/wiki/Lenny Podcast - Linear Founder.md`

```markdown
---
tags: [source, learning]
created: 2026-05-17
updated: 2026-05-17
sources: [iphone-capture-2026-05-16]
---

# Lenny Podcast — Linear Founder

Source page for podcast listens from Lenny's podcast featuring the founder of Linear.

## Episode notes — 2026-05-16

### Takeaway — Product taste compounds

Every small decision about how the product feels accumulates over years. Analogy: a chef tasting food at every step — quality is the product of continuous micro-judgment, not occasional big calls.

Application: when in doubt about a small detail, don't punt it. The aggregate of those small calls *is* the product.

## Cross-references

- [[Active Learning]]
- [[Career Direction]]
```

**Updated**: `career/wiki/Career Direction.md` — added a follow-up under Strategy:

```markdown
## Strategy

(...existing content...)

### Active follow-ups

- ML startup recruiter replied 2026-05-16 — screening call Wednesday 2pm. Prep before the call.
```

**Updated**: `career/wiki/Active Learning.md` — added Lenny podcast:

```markdown
## Currently Learning

- (existing items)
- **Lenny's podcast** — product/strategy interviews. Notes: [[Lenny Podcast - Linear Founder]]
```

**Updated**: both `wiki/log.md` files with new entries, both `wiki/index.md` files with the new pages.

## Step 5 — Skill appends to archive

`~/Library/Mobile Documents/com~apple~CloudDocs/_obsidian-capture/archive/2026-05.md`:

```markdown
# Capture archive — 2026-05

---

## Ingested 2026-05-16 21:00

<full contents of ingest.md above>
```

## Step 6 — Skill truncates and reports

`iphone-raw.md` → 0 bytes. `ingest.md` → 0 bytes. Both files still exist (Shortcut needs `iphone-raw.md` to exist as an append target).

Final report:

```
Synced 3 substantive bullets from iphone-raw.md (4 raw → 1 dropped as misfire)
  gym:    2 files touched
    - wiki/Run 2026-05-16 - 5k Morning.md (created)
    - wiki/log.md (entry added)
  career: 5 files touched
    - wiki/Lenny Podcast - Linear Founder.md (created)
    - wiki/Career Direction.md (Strategy follow-up added)
    - wiki/Active Learning.md (added to Currently Learning)
    - wiki/log.md (entry added)
    - wiki/index.md (Lenny podcast added under Sources)
Archived to: archive/2026-05.md
Cleared: iphone-raw.md, ingest.md
Unrouted: 0
```

## Notes

- The skill chose **page names** based on each vault's existing conventions (e.g., `Run YYYY-MM-DD - <title>` because that's the gym vault's pattern).
- It **created new pages** when no existing page fit (Run 5/16, Lenny podcast).
- It **updated existing pages** for incremental adds (Career Direction, Active Learning).
- It **dropped the misfire** silently and noted it in the dropped section.
- It **did not invent details** — every fact came from the dictation.

If the skill had encountered a bullet with no good home, it would have asked once (batched, at the end of routing) whether to create a new vault, route to an existing one, or discard.
