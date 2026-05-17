---
description: Drain iPhone voice-dictation capture into Obsidian vaults. Summarizes raw dictation, routes to vaults, archives, clears the inbox.
---

Invoke the `sync-phone` skill via the Skill tool. Follow its instructions exactly.

The skill will:
1. Read `iphone-raw.md` from the capture directory.
2. If non-empty, summarize into `ingest.md` with per-vault routing.
3. Apply bullets to vaults autonomously (asking only when a new vault might be needed).
4. Append `ingest.md` to `archive/YYYY-MM.md`.
5. Truncate `iphone-raw.md` and `ingest.md`.
6. Report what was synced.
