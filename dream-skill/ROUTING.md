# ROUTING.md — Disambiguation & Volatility Supplement

<!-- Hand-maintained. The router LLM reads this FIRST, before the nav-context block.
     STRUCTURE: never auto-generate this file. Rules are authored by humans.
     GAP LOG: append at the bottom when a fact won't route cleanly, then fold rules back up. -->

## 0. Source-of-truth precedence (applies during reconciliation, not routing)

1. User's words in the current conversation — always win.
2. Vault `wiki/` pages — source of truth for stable facts (newer `updated:` date wins).
3. Auto-memory files (`~/.claude/projects/.../memory/`) — stale cache; verify against vault.
4. Training-data priors — last resort; never override 1–3.

---

## 1. Which vault? — Cross-vault disambiguation rules

Rules are tried top-to-bottom. First match wins.

### 1.1 Tech / skill facts
- "used/learned/built with `<technology>`" → capability Bohdan **has** → **me** vault, `wiki/skills/<domain>.md`
- "decided to use `<technology>` inside `<repo name>`" → architectural choice → **projects** vault, `wiki/<project>.md`, section `Architecture`
- Rule: if the fact mentions a **named repo or codebase**, route to **projects** regardless of the technology.

### 1.2 Work/outreach facts
- A **named person** in a deal, outreach, or prospect context → **work** vault, current-cycle pipeline page.
- A **named person** who is a mentor, friend, or family → **me** vault, `wiki/contacts.md`.
- Disambiguation: if the sentence contains words like "follow-up", "call", "pitch", "sent", "deal", "client", "prospect" → work. Otherwise → me/contacts.

### 1.3 Course / study facts → personal-notes
- A **concept, insight, synthesis, lecture note, or exam prep item** from any course, MOOC, book, or self-directed study → **personal-notes** vault (`Notes/` folder).
- There is no separate `learning` vault in the active config; all study material routes to **personal-notes**.

### 1.4 Goals — strategic direction vs active cycle
- A fact about **who Bohdan is or wants to become** (durable identity, multi-year horizon) → **me** vault, `wiki/goals.md` or the relevant `12-Week Year` page.
- A fact about **what he is doing THIS cycle** (specific outreach target, sprint task, active deal) → **work** vault, current cycle.
- Disambiguation: if the fact would still be true in 6 months regardless of current work → me/goals. If it expires with the current 12-week cycle → work.

### 1.5 Fitness / body facts
- Anything about workouts, exercises, PRs, running, body stats, nutrition, supplements → **gym-sprint** vault.

### 1.6 App / tool configuration
- Keyboard shortcuts, app settings, dotfile preferences, cross-app sync → **setup** vault.

### 1.7 Projects vs me — experience entries
- A **role or internship** (Bohdan as an employee/contractor at company X) → **me** vault, `wiki/experience/<role>.md`.
- A **codebase or system** built during that role → **projects** vault, `wiki/<project>.md`.
- Both can be created; they are complementary.

### 1.8 Personal observations with no vault fit
- A transient logistical fact (location hours, weather, logistics) that does not describe Bohdan's identity, skills, projects, fitness, learning, setup, or active work → **status: gap**. Do not force a vault.

---

## 2. Volatility classification

Reconciliation (Plan 3) uses this table to choose `append` vs `replace` vs `stale`.

| Vault | Page / area | Volatility | Default reconcile action |
|-------|-------------|------------|--------------------------|
| me | `wiki/goals.md`, `wiki/goals/*` | **VOLATILE** | `replace` / `supersede` |
| me | `wiki/career.md` | VOLATILE | `replace` if same attribute |
| me | `wiki/experience/*.md` | STABLE | `append` new entries |
| me | `wiki/skills/*.md` | STABLE | `append` new evidence |
| me | `wiki/identity.md` | VOLATILE | `replace` location/status fields |
| projects | `wiki/<project>.md` → `## Current Goals` | VOLATILE | `replace` |
| projects | `wiki/<project>.md` → `## Architecture` | STABLE | `append` |
| projects | `wiki/<project>.md` → `## Known Issues` | STABLE | `append` |
| gym-sprint | active program pages | VOLATILE | `replace` when same variable |
| gym-sprint | PR / record pages | STABLE | `append` |
| work | `cycles/<current>/pipeline.md` | VOLATILE | `replace` deal status |
| work | `cycles/<current>/outreach/log.md` | STABLE | `append` |
| setup | `shortcuts-canonical.md` | VOLATILE | `replace` binding per action |
| personal-notes | `Notes/*.md` | STABLE | `append` |

---

## 3. Canonical page name rules

- Page names are **kebab-case**, lowercase, no spaces: `deep-learning.md`, `aximon.md`.
- The router must emit the **exact relative path** from the vault root that already exists in `wiki/index.md` or on disk (from the dir scan). Never invent a new path that isn't in the nav-context.
- If a matching page doesn't yet exist → emit `status: gap` with `gap_note` suggesting the new page path. Let Plan 4 / the user decide whether to create it.
- Exception: `work` vault pipeline pages follow the pattern `cycles/<cycle-id>/pipeline.md`. The active cycle ID is readable from the work vault's `wiki/index.md`. If ambiguous, emit `routing_confidence: medium`.

---

## 4. Confidence calibration

| Scenario | routing_confidence |
|----------|--------------------|
| Single vault, exact page match in index + dir scan | high |
| Single vault, page inferred by category (no exact match) | medium |
| Multiple candidate vaults, one eliminated by a rule above | medium |
| Multiple candidate vaults, no rule settles it | → status: ambiguous |
| No vault fits | → status: gap |
| Content is `confidence: low` in the candidate fact | cap routing_confidence at medium |

---

## 5. Routing-gaps log

Append a new entry here whenever a candidate produces `status: ambiguous` or `status: gap` and the rule does not yet exist above. After ≥3 similar gaps accumulate, fold a new rule into §1 or §2 above and delete those log entries.

Format:
```
- DATE | FACT (truncated 80 chars) | reason-no-rule | proposed-rule (optional)
```

<!-- === LOG START — add new entries below === -->

<!-- === LOG END === -->
