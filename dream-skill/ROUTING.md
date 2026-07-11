# Dream Routing Guide

Dream routes only to pages present in the bounded canonical page catalog built
from the configured vault roots. It never invents a vault, page, or section.
When the catalog does not settle the destination, return `status: gap` or
`status: ambiguous`; do not force a write.

## Routing priorities

Use the configured vault descriptions, page titles, headings, and the fact's
durability together. Prefer the narrowest existing page that directly owns the
fact.

| Fact type | Usual destination |
|---|---|
| Identity, preferences, career direction, long-lived goals, education, skills | The configured personal/profile vault |
| A repository, system design, technical decision, architecture, or known issue | The configured projects/codebases vault |
| Active work, prospects, outreach, deals, or time-boxed operating state | The configured work/operations vault |
| Workouts, body composition, nutrition, supplements, or running | The configured fitness vault |
| Symptoms, conditions, care plans, or treatment experiments | The configured health vault |
| Courses, study notes, exams, or reference material | The configured notes/learning vault |
| Keyboard shortcuts, app settings, or cross-tool setup | The configured setup/configuration vault |

If more than one configured vault fits, use the page catalog and local lexical
retrieval as the tie-breaker. If that remains inconclusive, emit `ambiguous`.

## People

`route-entities.py` deterministically pre-routes a fact only when it starts
with a full name found on an actual roster page (a Markdown file whose basename
is `People` or `people`). It never treats arbitrary files in a `people/`
directory as rosters.

- A roster fact goes to the matching roster page and current section.
- A name on multiple rosters uses the optional
  `entity_routing.preferred_vault` config value; otherwise the stable
  `(vault, page)` order wins.
- A detected but unknown subject-position full name is retained in the private
  per-run people-review artifact for human triage; it is never written to a
  vault automatically.
- Organization, product, and owner names that should not be detected as people
  belong in local `entity_routing.stop_terms` config, not this public file.

## Durability and reconciliation

Classify a fact before choosing an action:

- **Stable** facts add durable context such as skills, past experience,
  architecture, or established preferences.
- **Current** facts describe active work, a present role, a current project
  status, or other time-sensitive state.
- **Audit** and **dropped** candidates never reach routing.

Reconciliation may append a genuinely new stable fact. Supersede and
contradict decisions require an exact existing Markdown line and always need
review. Low-confidence candidates are capped at medium routing confidence.

## Canonical targets and gaps

- Emit the exact vault, relative page path, and section supplied in the batch
  allow-list.
- Prefer generated-wiki pages when the vault exposes a `wiki/index.md` catalog.
- Do not create pages, directories, or aliases.
- Route a fact with no durable persona, project, or operating value to `gap`.
- Preserve uncertainty: `gap` is safer than a plausible but wrong destination.

## Confidence

| Situation | Routing confidence |
|---|---|
| Exact page and section match in the allow-list | high |
| One configured domain fits but the exact section is inferred | medium |
| Multiple plausible vaults remain | ambiguous |
| No configured page owns the fact | gap |

Candidate confidence limits routing confidence: a low-confidence candidate may
not receive high routing confidence.
