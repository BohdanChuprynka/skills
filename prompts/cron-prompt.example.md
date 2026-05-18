# Cron prompt — calendar-plan auto

> This file is the **single source of truth** for the scheduled calendar-plan prompt.
> Both the Claude entrypoint (`claude/calendar-plan.sh`) and the Codex automation
> (`codex/automation.example.toml`) consume this body. Edit here; both runtimes
> pick up the change on next run.
>
> Placeholders resolved at install time:
>   `{{SKILL_DIR}}`           — absolute path to skill install dir
>   `{{PLANNING_PREFS}}`      — absolute path to planning-preferences.md
>   `{{MEMORY_FILE}}`         — absolute path to memory.md
>   `{{CALENDAR_CONTEXT}}`    — absolute path to Obsidian Calendar Context page
>   `{{TASK_SOURCE_NAME}}`    — name of the task-sequence source (e.g. "12-Week Planner")
>   `{{TIMEZONE}}`            — IANA timezone (e.g. "America/New_York")
>   `{{CRON_HOUR}}`           — local hour the cron fires (e.g. "22")

---

Use the `calendar-plan` skill in `/calendar-plan auto` mode.

Target date:
- This cron runs at {{CRON_HOUR}}:00 {{TIMEZONE}}. Plan tomorrow unless the current user prompt explicitly says otherwise.
- State the target date and timezone before writing anything.

Read sources in this order:
1. `{{PLANNING_PREFS}}`.
2. `{{MEMORY_FILE}}`.
3. Calendar Context page: `{{CALENDAR_CONTEXT}}`.
4. Google Calendar, querying every calendar ID listed in planning preferences, not only primary.
5. Notion private page titled `{{TASK_SOURCE_NAME}}` for tomorrow's task sequence.
6. Gmail for recent/important obligations, deadlines, errands, or replies.
7. This prompt.

Calendar Context sections:
- `Confirmed Upcoming Events` and `Hard Constraints` are hard constraints when dated for the target day.
- `Modifiers` are one-off overrides such as fatigue, no gym, altered school hours, travel, or reduced intensity.
- `Tentative / Unscheduled` items may fill open windows only after fixed obligations are placed.
- `Planning Notes` should shape intensity, block length, and recovery.
- `Recently Completed` is context only. Do not reschedule it.

Planning behavior:
- Compare existing Calendar Plan blocks for the target date with current calendar state before adding more. User edits, deletions, merges, and moved blocks are preference signal.
- Prefer a small number of durable blocks over a packed ideal day.
- On school days, include a realistic landing buffer after school or exams before heavy work.
- On exam/appointment days, protect check-in, commute, and reset time before adding hard work.
- Do not split deep work into multiple pieces unless a real fixed event requires the split.
- Do not create 5-minute overlaps across calendars. Use transitions.
- If Notion or Gmail is unavailable, create only a conservative scaffold when calendar state and recurring preferences are enough. Pause for uncertain priorities, destructive changes, or hard conflicts.

Safe actions:
- Create new planning/support blocks for clear tasks, fixed-calendar-derived study, recurring preference blocks, meals, commute, buffers, and recovery.
- Do not delete events.
- Do not move or rewrite existing non-planning events.
- Do not modify the Calendar Context page.
- Pause instead of writing if locations, priorities, stale exam events, conflicts between sources, or missing connectors could materially change the day.

After writing:
- Re-query all configured calendars for the target date.
- Report created/changed blocks with calendar names.
- Report any remaining overlaps, stale duplicates, missing sources, assumptions, or blockers.
- Append durable observations to automation memory; do not replace prior memory history unless the user explicitly asks for compaction.
