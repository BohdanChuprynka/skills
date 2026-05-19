# skills

Personal Claude Code skills monorepo. Each subdirectory is a self-contained skill with its own README, install instructions, and license.

## Skills

| Skill | Purpose |
|-------|---------|
| [calendar-plan-skill](./calendar-plan-skill) | Dual-target Claude Code + Codex CLI skill for daily calendar planning with isolated, per-skill MCP credentials. |
| [sync-phone](./sync-phone) | iPhone voice-dictation capture to Obsidian vault pipeline. Drains iCloud dictation inbox, summarizes, routes by vault, archives, clears. |
| [dream-skill](./dream-skill) | Reconcile your Obsidian wiki against Claude Code session signals — flag stale, missing, and contradicted facts for review. |

## Layout

Each skill lives in its own folder with full history preserved (merged via `git subtree`). Open the folder's README for install + usage.

## History

These three skills previously lived in separate repos (`calendar-plan-skill`, `sync-phone`, `dream-skill`). Consolidated here for shared maintenance and discoverability. Original repos are archived.
