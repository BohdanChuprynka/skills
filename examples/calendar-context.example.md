# Calendar Context

Upcoming dates and items relevant to future scheduling. The calendar planner reads this alongside Google Calendar, Notion, Gmail, and local planning preferences.

> Lives in your Obsidian vault (or any markdown file the agent can read). The planner READS this file and treats it as durable context — it does NOT write to it.

Only durable scheduling context belongs here: dated constraints, temporary modifiers, tentative obligations, and planning notes that help future calendar plans fit real life.

## Confirmed Upcoming Events

<!-- Format: - YYYY-MM-DD [HH:MM] — <event or item> (captured YYYY-MM-DD) -->

- 2026-12-01 — **Example fixed event**. Description. (captured 2026-05-01)

## Hard Constraints

<!-- Format: - YYYY-MM-DD [HH:MM-HH:MM] — <constraint> (captured YYYY-MM-DD) -->

- 2026-06-15 09:00-12:00 — **Exam block, do not schedule over** (captured 2026-05-01)

## Modifiers

<!-- One-off overrides that change a specific day. Format: - YYYY-MM-DD — <modifier> (captured YYYY-MM-DD) -->

- 2026-05-20 — Travel day, no gym, reduced evening intensity (captured 2026-05-18)
- 2026-05-22 — Low-energy day, target a single deep-work block (captured 2026-05-18)

## Tentative / Unscheduled

<!-- Items that should fill open windows after fixed obligations. Format: - <item> — <hint> (captured YYYY-MM-DD) -->

- Draft cover letter — needs ~90 min focus (captured 2026-05-15)
- Review pending PRs — slot anywhere mid-afternoon (captured 2026-05-16)

## Planning Notes

<!-- Free-form guidance the planner should weigh. -->

- This week has back-to-back deadlines. Prefer one solid morning block over many small ones.

## Recently Completed

<!-- Context only. Do not reschedule. Format: - YYYY-MM-DD — <completed item> -->

- 2026-05-15 — Submitted application
