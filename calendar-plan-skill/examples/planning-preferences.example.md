# Calendar Planning Preferences

User-specific data for the `calendar-plan` skill. Keep `SKILL.md` generic; put personalization here.

> **Copy this file** to `<skill-install-dir>/config/planning-preferences.md` and edit. The real file is gitignored.

## Source Order

1. Google Calendar: fixed events, busy windows, existing planning blocks, locations.
   - `Primary`: `<your-primary-email@example.com>`
   - `<Calendar Label 1>`: `<calendar-id-1@group.calendar.google.com>`
   - `<Calendar Label 2>`: `<calendar-id-2@group.calendar.google.com>`
   - `<Calendar Label 3>`: `<calendar-id-3@group.calendar.google.com>`
   - Query all listed calendar IDs directly; do not rely only on `primary`.
2. Notion: private page titled `<Your Planner Page Title>`.
   - Canonical source for daily goals and task sequence.
   - If modern Notion search cannot find it, fallback Notion page ID `<notion-page-uuid>` / `https://www.notion.so/<notion-page-id>`.
3. Gmail: recent and important email signals.
   - Use only for real obligations, deadlines, errands, replies, or commitments that may not be on calendar.
4. User prompt: run-specific constraints, goals, energy notes, or changes for this run.

## Daily Defaults

- Weekday wake-up: `<HH:MM AM>`.
- Weekend wake-up: `<HH:MM AM>`.
- Do not schedule ordinary planning blocks before wake-up unless a fixed commitment already requires it or the user explicitly asks.
- Include a `Deep Work` / `Lock In` block in daily plans even when the task source omits one.
- Deep work can be startup work or other meaningful personal work.
- Prefer one clean deep-work block over multiple split blocks when no hard event truly requires the split.
- Preferred deep work golden hours:
  - `<HH:MM AM>` — `<HH:MM PM>`.
  - `<HH:MM PM>` — `<HH:MM AM>`.
- Lower-energy window: `<HH:MM PM>` — `<HH:MM PM>`. Use it when needed, but prefer not to place the hardest work there.
- Flexible sports/workouts: schedule at `<HH:MM PM>` or later by default unless fixed calendar events or explicit user instructions say otherwise.
- If a workout, run, or sport block already exists on any configured calendar, treat it as fixed and do not add another workout that day.
- On school/work days, leave a `30-45 minute` landing buffer after school or an exam before the first serious focus block unless the user explicitly asks for an immediate start.
- After exams, appointments, or other high-friction commitments, use a `60-90 minute` reset window before heavy work when the calendar allows.
- On weekends, default to ending planned productive work by about `<HH:MM PM>` unless the user has an explicit evening commitment or asks for late work.
- Put closure tasks (e.g. `Daily commit`) near the end of the productive work sequence.

## Commute Assumptions

- `<Location A>` commute: `<N minutes>` each way by `<mode>` unless the user gives a different commute for that day.

## Calendar Routing

- `<Calendar Label 1>`: `<what goes here>`.
- `<Calendar Label 2>`: `<what goes here>`.
- `<Calendar Label 3>`: `<what goes here>`.
- `Primary`: fallback only when no specific calendar fits or the user asks for primary.

## Examples

- `<YYYY-MM-DD>` example: `<HH:MM>` — `<HH:MM PM>` was intended as deep work time.

## Audit-Derived Planner Corrections

- Query all configured calendars before writing and after writing. Actual conflicts often happen across calendar boundaries, not inside one calendar.
- Avoid 5-minute overlaps between flexible blocks. Use at least a 5-10 minute transition when switching block types.
- Do not create generic `New Event` planning blocks. If an existing event has a generic title, inspect its time and source, preserve it as a fixed hold, and flag it if it conflicts with the proposed plan.
- If the user corrects an event name, date, or time, ask whether contradictory old events should be deleted or updated instead of preserving both.
- When a user later merges two adjacent work blocks, prefer a single larger block of that type in future plans.
- If Notion or Gmail is unavailable during the scheduled run, a conservative calendar-only scaffold is allowed when the fixed calendar and recurring preferences are enough: wake/school/commute, meals, one deep-work block, one closure block, known exam prep from calendar, and existing workout. Pause only for uncertain priorities or destructive changes.
