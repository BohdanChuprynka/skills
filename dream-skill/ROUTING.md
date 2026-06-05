# ROUTING.md - Disambiguation and Volatility Supplement

<!-- Hand-maintained. The ROUTE agent reads this before the nav-context block.
     STRUCTURE: never auto-generate this file. Rules are authored by humans.
     GAP LOG: routing gaps are written to routing-gaps.log, then recurring
     patterns can be folded back into the rules below. -->

## 0. Source-of-truth precedence

This section informs reconciliation, not routing.

1. User's words in the current conversation always win.
2. Vault `wiki/` pages are the source of truth for stable facts; newer `updated:` dates win.
3. Auto-memory files under `~/.claude/projects/.../memory/` are stale cache; verify against vault pages.
4. Training-data priors are last resort and never override 1-3.

## 1. Which vault?

Rules are tried top-to-bottom. First match wins.

### 1.1 Tech and skill facts

- "used/learned/built with `<technology>`" means a capability Bohdan has; route to the `me` vault, normally under `wiki/skills/`.
- "decided to use `<technology>` inside `<repo name>`" is an architectural choice; route to the `projects` vault, the named project page, section `Architecture`.
- If the fact mentions a named repo or codebase, route to `projects` even when the sentence also mentions a technology.

### 1.2 Work and outreach facts

- A named person in a deal, outreach, client, or prospect context routes to the `work` vault, current-cycle pipeline page.
- A named person who is a mentor, friend, classmate, or family member routes to the `me` vault, normally contacts/relationships.
- If the sentence contains words like "follow-up", "call", "pitch", "sent", "deal", "client", or "prospect", prefer `work`.

### 1.3 Course and study facts

- A concept, insight, synthesis, lecture note, or exam prep item from a course, MOOC, book, or self-directed study routes to `personal-notes`.
- In the current active config, study material routes to `personal-notes`; do not invent a separate `learning` route unless the nav-context shows one.

### 1.4 Goals and active cycle work

- A fact about who Bohdan is or wants to become on a durable, multi-month horizon routes to `me`, normally goals or identity pages.
- A fact about what he is doing in the current sprint/cycle, especially a specific outreach target, sprint task, active deal, or weekly send, routes to `work`.
- If the fact would still be useful in six months regardless of current work, prefer `me`. If it expires with the current cycle, prefer `work`.

### 1.5 Fitness and body facts

- Workouts, exercises, PRs, running, body stats, body composition, nutrition, and supplements route to `gym-sprint`.

### 1.6 App and tool configuration

- Keyboard shortcuts, app settings, dotfile-adjacent preferences, and cross-app sync route to `setup`.

### 1.7 Projects vs. personal experience

- A role, internship, contractor relationship, or work experience entry about Bohdan routes to `me`, normally experience/career pages.
- A codebase or system built during that role routes to `projects`, normally the project page.
- Both may be represented in separate vault pages when the facts describe different things.

### 1.8 No durable persona fit

- A transient logistical fact that does not describe Bohdan's identity, skills, projects, fitness, learning, setup, or active work routes to `status: gap`.
- Do not force a vault just to avoid a gap.

## 2. Volatility classification

Reconciliation uses volatility to choose append vs. replace vs. stale.

| Vault | Page or area | Volatility | Default reconcile action |
|---|---|---|---|
| me | `wiki/goals.md`, `wiki/goals/*` | VOLATILE | supersede same-subject active state |
| me | `wiki/career.md` | VOLATILE | supersede same-attribute career status |
| me | `wiki/experience/*` | STABLE | append new evidence or entries |
| me | `wiki/skills/*` | STABLE | append new evidence |
| me | identity / bio status pages | VOLATILE | supersede location/status fields |
| projects | project `## Current Goals` | VOLATILE | supersede same goal/status |
| projects | project `## Architecture` | STABLE | append additive architecture facts |
| projects | project `## Known Issues` | STABLE | append additive issues |
| gym-sprint | active program pages | VOLATILE | supersede same variable |
| gym-sprint | PR / record pages | STABLE | append |
| work | current-cycle pipeline | VOLATILE | supersede deal/prospect status |
| work | outreach log | STABLE | append |
| setup | canonical shortcuts/settings | VOLATILE | supersede binding per action |
| personal-notes | notes pages | STABLE | append |

## 3. Canonical page name rules

- The router must emit the exact relative path from the vault root that already exists in `wiki/index.md` or the nav-context dir scan.
- Never invent a new path. If a matching page does not exist, emit `status: gap` and explain the proposed path in the routing-gaps log.
- Page names are normally lowercase kebab-case, but existing vault paths win over naming preferences.
- Work vault pipeline pages may use current-cycle paths. If the active cycle is ambiguous, emit `routing_confidence: medium` or `status: ambiguous`.

## 4. Confidence calibration

| Scenario | routing_confidence |
|---|---|
| Single vault, exact page match in index and dir scan | high |
| Single vault, page inferred by category with no exact title match | medium |
| Multiple candidate vaults, one eliminated by a rule above | medium |
| Multiple candidate vaults, no rule settles it | `status: ambiguous` |
| No vault fits | `status: gap` |
| Candidate fact has `confidence: low` | cap at medium |

## 5. Routing-gaps log

Routing gaps are appended by the orchestrator to:

```text
${DREAM_HOME:-$HOME/.claude/dream-skill}/routing-gaps.log
```

Do not write gaps into this file during a run. This file is hand-maintained guidance.

Log line format:

```text
- DATE | FACT (truncated 80 chars) | reason-no-rule | proposed-rule (optional)
```

When three or more similar gaps accumulate, fold a rule into sections 1-4 and clear the corresponding gap entries.
