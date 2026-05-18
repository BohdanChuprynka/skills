# Calendar Plan Automation Memory

Append-only durable observations from `calendar-plan auto` runs. Do not replace prior history unless the user explicitly requests compaction.

> **Copy this file** to `<skill-install-dir>/memory/memory.md` and let the automation append to it. The real file is gitignored.

## Format

Each run appends one block:

```
## YYYY-MM-DD HH:MM <TZ> — <run-id>

target_date: YYYY-MM-DD
mode: auto | draft
connectors_status: { google-calendar: ok, notion: ok, gmail: ok, filesystem: ok }

observations:
- <durable observation that should affect future runs>
- <pattern detected across edits>
- <connector or data anomaly worth remembering>

actions_taken:
- created  <calendar-name>  HH:MM-HH:MM  <event title>
- changed  <calendar-name>  HH:MM-HH:MM  <event title>  (was HH:MM-HH:MM)
- pause-no-write: <reason>

followups:
- <thing user should resolve before next planner run>
```

## Example entry

```
## 2026-05-17 22:00 EDT — run-2026-05-17T22:00:00-04:00

target_date: 2026-05-18
mode: auto
connectors_status: { google-calendar: partial, notion: degraded, gmail: missing-tool }

observations:
- School calendar returned UNAUTHORIZED for configured ID. Other calendars worked.
- Notion search could not locate the configured task-source page; nothing was placed from task source.
- Gmail tool was not exposed by tool discovery this run; deadline scan skipped.

actions_taken:
- pause-no-write: Notion + Gmail both unavailable on a school night; conservative scaffold would not be safe with missing task source.

followups:
- Investigate School calendar OAuth scope.
- Confirm Notion page slug.
```
