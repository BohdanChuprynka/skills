---
name: calendar-plan
description: >
  Use when the user says "plan my day", "plan today", "plan tomorrow",
  "draft tomorrow's calendar", "run calendar-plan", "/calendar-plan",
  "schedule today", "schedule tomorrow", or wants to build a practical
  daily plan from Google Calendar, a Notion task page, Gmail signals, and
  a local Calendar Context note. Target date is resolved by local clock
  time: morning/afternoon runs (before 16:00) plan TODAY; late-evening
  runs (20:00+) plan TOMORROW; the 16:00–20:00 window defaults to
  tomorrow and is called out in the draft. Explicit user wording
  ("today" / "tomorrow" / a named day) always wins. Two modes:
  /calendar-plan (draft first, ask before writing) and /calendar-plan auto
  (apply safe planning blocks directly, pause for risky changes). Pairs
  with a scheduled launchd job that fires the auto mode each evening.
  Do NOT use for general scheduling questions, calendar Q&A, or anything
  that does not involve writing planning blocks to Google Calendar.
---

# Calendar Plan

Create a simple, calendar-ready day plan from existing commitments and goal sequence.

Before each run, read `~/.config/calendar-plan/preferences.md` (the personal config path outside the skill repo). Treat that file as the source for user-specific calendar IDs, task source names, daily defaults, commute assumptions, and calendar routing. Keep this `SKILL.md` generic. If the file is missing, fall back to the example at `config/settings.example.conf` and warn the user.

## Modes

- `/calendar-plan`: draft first. Gather context, propose the plan, then wait for user approval before creating or updating calendar events.
- `/calendar-plan auto`: apply safe planning blocks directly. Pause only for risky or ambiguous actions.

Safe actions in auto mode:

- Create new calendar blocks for clear tasks from the configured task sequence source.
- Add reasonable buffers, meals, breaks, and commute holds around fixed commitments.
- Adjust only newly proposed planning blocks before writing them.

Pause before:

- Deleting events.
- Moving or rewriting existing non-planning events.
- Mass-rescheduling.
- Acting on unclear locations, unclear priorities, hard overlaps, or missing configured task-source context.

## Sources

Use these sources in order:

0. `~/.config/calendar-plan/preferences.md`: configured accounts, source names, defaults, commute assumptions, and calendar routing.
1. Calendar sources listed in preferences: fixed meetings, existing blocks, locations, all-day events, busy windows.
2. Task sequence source listed in preferences: canonical daily goals and their sequence.
3. Email source listed in preferences: recent and important signals for meetings, deadlines, errands, replies, or commitments that may not be on calendar.
4. User prompt: extra constraints, goals, energy notes, or changes for this run.

If a connector is unavailable, state the gap and continue with available sources. In `/calendar-plan auto`, do not write calendar blocks when the missing source could materially change the day.

## Run Context

- Resolve the target date and timezone explicitly before reading or writing calendar events. State the resolved date in the draft so the user can catch a mistake before any write.
- Default the target date by the **local clock time at the moment of the run**, not by assuming "next day". The point is to match the user's intent: morning planning is for the day ahead of you; late-night planning is for the day waking up to.
  - **00:01 to 16:00 local (just past midnight through mid-afternoon)** → plan for **today**, the current calendar date. Example: a run started Monday 08:00 places blocks on Monday.
  - **20:00 to 24:00 local (late evening through midnight)** → plan for **tomorrow**, the next calendar date. Example: a run started Monday 22:00 places blocks on Tuesday.
  - **16:00 to 20:00 local (late afternoon transition window)** → ambiguous. Default to **tomorrow**, but call this out explicitly in the draft (`Resolved target date: <date> — clock is in the 16:00–20:00 window, defaulted to tomorrow; say "plan today" to flip.`) so the user can override in one line. Scheduled launchd runs fire in the evening and resolve naturally to tomorrow under this rule.
- Explicit user wording always overrides the clock-based default. "Plan today" / "today" → current calendar date. "Plan tomorrow" / "tomorrow" / "schedule tomorrow" → next calendar date. A named day ("plan Friday") → that specific date. Never invert these — if the user said "today", do not silently shift to tomorrow because the clock is late.
- Before writing, inspect existing events on all configured calendars for the target date. Also peek at the following morning when late-night blocks may spill over, and at the previous evening when early-morning runs may inherit unfinished commitments.
- If a previous Calendar Plan run already wrote blocks for the target date, compare those blocks with the current calendar before adding more. Treat user edits, deletions, merges, and time shifts as preference signal for the new plan.

## Planning Rules

- Treat existing Google Calendar events as hard constraints unless the user explicitly asks to change them.
- Plan around existing calendar blocks; do not overwrite or ignore them.
- Read today's entry/section in the configured task sequence source first.
- Preserve the configured task-source order as intentional sequence data.
- Do not infer task placement from task type or topic. For example, do not assume commits, study, admin, or errands belong early or late unless task-source order, calendar constraints, deadlines, commute, or user instructions say so.
- Prefer fewer useful blocks over a packed ideal day.
- Include realistic transition time between blocks.
- Avoid creating many short adjacent blocks when one clear work block plus a named outcome would better match the user's actual behavior.
- Account for meals, short breaks, and recovery space when the day is long.
- Keep focused work blocks sized realistically; split oversized tasks instead of making one huge event.
- Use email only to surface real obligations or likely tasks, not to overrule the configured task sequence without a clear reason.
- For exam or appointment days, protect the fixed commitment first, add commute/check-in/reset time, then schedule only the most important follow-up work.
- If the calendar contains a stale or contradictory exam/deadline event, pause and ask before deleting it. Do not leave two conflicting exam events silently.

## Daily Defaults

- Load daily defaults from `~/.config/calendar-plan/preferences.md` before placing flexible blocks.
- Do not schedule ordinary planning blocks before the configured wake-up time unless the calendar already has a fixed commitment or the user explicitly asks.
- Add recurring preference blocks from `~/.config/calendar-plan/preferences.md` even when the task source omits them.
- Place focus work according to configured energy windows when possible.
- If preferences conflict with fixed calendar events or explicit user instructions, fixed events and explicit user instructions win.

## Commute Handling

- If an event has a physical location or a task clearly requires travel, reserve commute time before and after it.
- Use commute assumptions from `~/.config/calendar-plan/preferences.md` when available.
- If exact commute cannot be determined, use a conservative local buffer and mark the assumption in the draft.
- In `/calendar-plan auto`, pause before writing commute-sensitive blocks when the location is ambiguous or the buffer could affect fixed events.
- Do not create impossible back-to-back location changes.

## Draft Output

For `/calendar-plan`, return:

1. Connected account/calendar used.
2. Fixed calendar events for the day.
3. Task sequence found for today.
4. Email-derived obligations, if any.
5. Proposed agenda with times.
6. Calendar changes that would be created or updated.
7. Any assumptions or conflicts.

Ask for approval before writing.

## Calendar Write Rules

- Use plain task names as event titles, e.g. `AP Study`.
- Do not prefix titles with `Plan:`, `Focus:`, or similar tags.
- Put brief rationale/source notes in the event description when useful, not in the title.
- Create each block on the matching calendar from `~/.config/calendar-plan/preferences.md` instead of defaulting to primary.
- If no configured calendar mapping fits, use the configured fallback calendar or pause when the choice could matter.
- Prefer creating new planning blocks over editing existing fixed events.
- Never create overlapping planning blocks across configured calendars unless the overlap is an intentional transparent hold and the reason is stated.
- After writing, re-query the target date across all configured calendars and report any remaining overlaps, stale duplicates, or blocks that differ from the intended plan.
- When writing, report exactly what was created or changed, including the calendar used for each block.

## Learning From Runs

- Calendar Plan memory is append-only by default. Add dated observations; do not replace prior history unless the user explicitly requests compaction.
- Capture durable preferences, recurring corrections, and repeated user edits. Do not store private transcript dumps or irrelevant work-output telemetry.
- When actual calendar edits show a repeated pattern, update `~/.config/calendar-plan/preferences.md` instead of relying on memory alone.
- If the user has to manually refine the same class of block twice, treat that as a planner bug to fix in preferences or this skill.

## Quality Bar

A good calendar plan:

- Makes the next action obvious.
- Respects the real calendar.
- Follows the configured task sequence.
- Leaves enough buffer to execute without constant replanning.
- Explains tradeoffs only when needed.
