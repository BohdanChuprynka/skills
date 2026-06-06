---
name: calendar-plan
description: >
  Use when the user says "plan my day", "plan today", "plan tomorrow",
  "draft tomorrow's calendar", "run calendar-plan", "/calendar-plan",
  "schedule today", "schedule tomorrow", or wants to build a practical
  daily plan and write events into Google Calendar. Target date is
  resolved by local clock at invocation: <16:00 → today; ≥16:00 →
  tomorrow. Explicit user wording ("today" / "tomorrow" / a named day)
  always wins. Single mode: draft first, write on approval. Calendar is
  the ONLY data source — no Notion, no Gmail, no other MCPs. Do NOT use
  for general scheduling questions or calendar Q&A that does not involve
  writing planning blocks to Google Calendar.
---

# Calendar Plan

Write a practical day plan as Google Calendar events from the user's stated goals + the existing fixed calendar.

Before each run, read `~/.config/calendar-plan/preferences.md` for calendar IDs, category routing, daily defaults, and commute assumptions. Read `~/.config/calendar-plan/observed-patterns.md` for inferred-from-history defaults (gym slots, meal cadence, deep-work block lengths). Keep this `SKILL.md` generic — personalization lives in those two files.

## Mode

Single mode: draft first, write on approval.

1. Resolve target date.
2. Read existing fixed events on target date across all configured calendars.
3. Ask the user for goals if not already provided in the prompt.
4. Propose a schedule with times + category labels.
5. On user approval, write events to Google Calendar using correct category routing.
6. Re-query after write. Report events created + flag any overlaps or anomalies.

No auto mode. No launchd. User invokes manually.

## Sources

Google Calendar is the ONLY data source consulted by this skill. Notion, Gmail, file-based task lists, or other MCPs are NOT read.

Inputs the skill uses on each run:

1. `~/.config/calendar-plan/preferences.md` — calendar IDs, category → calendar map, daily defaults, commute assumptions.
2. `~/.config/calendar-plan/observed-patterns.md` — patterns learned from past calendar history (separate file, append-only).
3. Existing events on the target date across all configured calendars — treated as hard constraints.
4. User prompt — goals, fixed commitments, energy notes, overrides for this run.

If a calendar account or calendar ID is unavailable, state the gap explicitly and stop until resolved. Do not silently fall back to a single calendar.

## Target Date Resolution

Resolve by local clock at invocation time.

- `00:01 - 15:59 local` → **today** (current calendar date).
- `16:00 - 23:59 local` → **tomorrow** (next calendar date).

Explicit user wording always overrides the clock-based default:

- "today" / "plan today" → current calendar date.
- "tomorrow" / "plan tomorrow" → next calendar date.
- Named day ("plan Saturday") → that specific date.

State the resolved target date and the reasoning ("clock = 22:14 → defaulted to tomorrow") in the draft so the user can catch a mistake before any write.

## Categories

Four categories. Each routes to one calendar per `preferences.md`.

| Category | Covers |
|---|---|
| Productive | Self-directed work, deep work, side projects, outreach, open-source contributions, any non-paid technical grind |
| Job | Paid employer time (current paid role + any future paid work for someone else) |
| School | School subjects, CCP coursework, exams, rec letters, college applications, anything academic |
| Personal | Gym, family, partner, drive, errands, recovery, social, meals when standalone |

The Productive ↔ Job split is conceptual (paid vs self-directed); both may route to the same calendar per user config — see `preferences.md`. Differentiate via event titles, not separate calendars.

If a block doesn't fit any category cleanly, ask the user before defaulting to a fallback calendar.

## Planning Rules

- Treat existing Google Calendar events as hard constraints unless the user explicitly asks to change them.
- Plan around fixed blocks; never overwrite or ignore them.
- Prefer fewer useful blocks over a packed ideal day.
- Realistic transitions between blocks — at least 5-10 min when switching context, location, or category.
- Account for meals, short breaks, and recovery space on long days.
- Keep focused work blocks realistically sized — split oversized tasks instead of one huge event.
- Honor energy windows from `preferences.md` when placing flexible blocks.
- For exam, job, or appointment days, protect the fixed commitment first, add commute and reset time, then schedule the most important follow-up work.
- If the calendar contains a stale or contradictory event, pause and ask before deleting it. Never leave two conflicting events silently.

## Daily Defaults

Load from `~/.config/calendar-plan/preferences.md` and `~/.config/calendar-plan/observed-patterns.md` before placing flexible blocks.

- Wake-up time defaults (weekday/weekend) come from `preferences.md`.
- Do not schedule ordinary planning blocks before wake-up unless the calendar has a fixed commitment or the user explicitly asks.
- Recurring preference blocks (workouts, deep-work blocks, closure tasks) are added even if the user did not name them in this run's goals.
- Place focused work in the configured golden hours when possible; reserve lower-energy windows for procedural / lower-cognitive tasks.
- If preferences conflict with fixed calendar events or explicit user instructions, fixed events and explicit user instructions win.

## Commute Handling

- Reserve commute time before and after any event with a physical location.
- Use commute assumptions from `preferences.md`.
- If exact commute is unknown, use a conservative local buffer and mark the assumption in the draft.
- Never create impossible back-to-back location changes.

## Draft Output

For each invocation, return in this order:

1. Resolved target date (with reasoning if clock-derived).
2. Fixed events already on the target date across all configured calendars.
3. User-stated goals for the day (echo back).
4. Proposed agenda with times + category labels.
5. List of events to be created (title, calendar, start, end).
6. Any assumptions, conflicts, or open questions.

Ask for approval before writing.

## Calendar Write Rules

- Use plain task names as event titles ("Cold outreach", "Gym", "Feature build"). No "Plan:" / "Focus:" prefixes.
- Put rationale or sub-tasks in the event description, not the title.
- Write each block to the calendar matching its category per `preferences.md`.
- Never create overlapping planning blocks across calendars unless the overlap is an intentional transparent hold and the reason is stated in the description.
- After writing, re-query the target date across all configured calendars. Report:
  - Events created (with calendar used for each)
  - Any remaining overlaps
  - Stale duplicates
  - Anything that differs from the intended plan
- Report exactly what was written.

## Learning From Runs

- Append observed patterns to `~/.config/calendar-plan/observed-patterns.md` after meaningful recon runs or when the user's edits reveal a recurring preference.
- This file is append-only by default. Add dated observations; do not replace prior history unless the user explicitly requests compaction.
- Capture: repeated user edits, recurring corrections, durable preferences inferred from history.
- Do not store private transcript dumps or irrelevant work-output telemetry.
- If the user has to manually refine the same class of block twice, treat that as a planner bug to fix in `preferences.md` or this skill.

## Quality Bar

A good calendar plan:

- Makes the next action obvious.
- Respects the real calendar.
- Honors the user's stated goals + the category routing.
- Leaves enough buffer to execute without constant replanning.
- Explains tradeoffs only when needed.
