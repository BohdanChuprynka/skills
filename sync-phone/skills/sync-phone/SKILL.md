---
name: sync-phone
description: Drain iPhone voice-dictation capture into Obsidian vaults. Reads a raw dictation sink file (appended to by an iPhone Shortcut), summarizes it into clean bullets, routes the bullets into the right LLM-curated Obsidian vault, archives the summary, and clears the inbox. Use whenever the user says "/sync-phone", "drain my inbox", "process my phone notes", "sync my phone capture", "ingest iphone-raw", "process my iCloud capture", or mentions wanting to move dictated thoughts from their phone into their Obsidian brain. Auto-trigger any time the user references their phone-capture inbox, raw dictation backlog, or asks to clear their phone notes into the wiki.
---

# sync-phone

Drain raw iPhone voice-dictation captures into Obsidian vaults.

## Mental model

The user dictates thoughts into an iPhone Shortcut throughout the day. The Shortcut appends `## YYYY-MM-DD HH:MM` headers + dictated text to a single `iphone-raw.md` file in iCloud Drive. This skill is the Mac-side drain step: read the raw, summarize into clean bullets, route to the right Obsidian vault, archive the summary, and empty the inbox.

The goal is to keep `iphone-raw.md` close to empty so it can be reviewed at a glance, and to keep the user's LLM-curated knowledge base fresh.

## Paths (configurable)

Defaults below assume the standard install. Override by editing this section if your layout differs.

```
CAPTURE_DIR = ~/Library/Mobile Documents/com~apple~CloudDocs/_obsidian-capture
VAULTS_DIR  = ~/Documents/Obsidian
```

Inside `CAPTURE_DIR`:
- `iphone-raw.md`  — capture sink, gets truncated each run
- `ingest.md`      — working scratchpad with the cleaned bullets, gets truncated each run
- `archive/YYYY-MM.md` — append-only audit of summarized bullets (raw dictation is **not** archived)

Vaults are auto-discovered: every directory under `VAULTS_DIR` that contains a `CLAUDE.md` is treated as a routable vault. Re-check at runtime; do not hardcode vault names. The vault's `CLAUDE.md` is the authority on its schema, page conventions, and ingest protocol.

## Workflow

### 1. Read the inbox

Read `$CAPTURE_DIR/iphone-raw.md`.

- If empty or only whitespace → report "nothing to process" and stop.
- Otherwise, parse out each timestamped block (`## YYYY-MM-DD HH:MM` header followed by dictated body).

### 2. Load vault routing context

For every vault directory in `$VAULTS_DIR` that contains a `CLAUDE.md`, read:
- `CLAUDE.md` (schema, ingest protocol, conventions)
- `wiki/index.md` (catalog of current pages — tells you which pages exist before you create new ones)

Cache this in working memory for the rest of the run.

### 3. Summarize into `ingest.md`

Transform raw dictation into clean, factual bullets. Rules:

- One bullet per discrete thought. Split rambling dictations into multiple bullets.
- Strip filler ("uh", "so basically", "what I want to say is"). Keep substance.
- Convert relative dates ("tomorrow", "Thursday") to absolute dates using the current date.
- Preserve specific numbers, names, places, decisions verbatim.
- If the same thought repeats across multiple captures, dedupe into one bullet and note the strongest source date.

Write to `$CAPTURE_DIR/ingest.md` in this exact structure:

```
# ingest.md — YYYY-MM-DD HH:MM batch

## <vault-name>
- [target page or "new: <page-name>"] <bullet>
- ...

## <vault-name>
- ...

## unrouted
- [why it doesn't fit] <bullet>
```

The `[target page or "new: ..."]` prefix is required — it makes the routing explicit so step 4 is mechanical. `new:` means the target page doesn't exist yet and must be created.

### 4. Route to vaults (autonomous)

For each bullet under each vault section:

- If `[target page]` exists → read the page, apply the bullet using the vault's ingest protocol (from its `CLAUDE.md`). Preserve frontmatter rules. Use wikilinks per the vault's convention.
- If `new: <page-name>` → create the page following the vault's page-creation convention from `CLAUDE.md` (frontmatter, location, naming).

No per-vault approval — apply everything. Track every file path touched for the final report.

**Exception — new vault needed.** If a bullet doesn't fit any existing vault, do not silently drop or force-route it. Surface it. After completing all routable bullets, ask the user whether to create a new vault, route to an existing one, or discard. Batch all such cases into a single question. Wait for the answer before archiving.

### 5. Archive the summary

Determine archive file: `$CAPTURE_DIR/archive/YYYY-MM.md` (current month).

If the file does not exist, create it with a header:
```
# Capture archive — YYYY-MM
```

Append the contents of `ingest.md` (the cleaned bullets, **not** the raw dictation) wrapped in a timestamped block:
```

---

## Ingested YYYY-MM-DD HH:MM

<full contents of ingest.md>
```

### 6. Clear the working files

After the archive append succeeds:
- Truncate `iphone-raw.md` to zero bytes — file must continue to exist because the iPhone Shortcut appends to it.
- Truncate `ingest.md` to zero bytes.

Use `: > path` or `truncate -s 0 path` via Bash. Do not delete the files.

### 7. Report

Print a compact summary to the user:

```
Synced N bullets from iphone-raw.md
  <vault-1>: M files touched (a.md, b.md)
  <vault-2>: M files touched (...)
Archived to: archive/YYYY-MM.md
Cleared: iphone-raw.md, ingest.md
Unrouted: 0    (or list)
```

## Routing heuristics

Routing is driven by each vault's `CLAUDE.md`. Read the schema, the page categories, and the "When to consult" guidance the vault defines. Match each bullet to the vault whose scope it falls under.

When two vaults could apply, prefer the more specific one (e.g., a workout journal entry goes to a `gym` vault, not a generic `notes` vault).

If the user maintains a global `~/.claude/CLAUDE.md` with a "When to consult a vault" table, treat that as the primary routing cheat sheet.

When the bullet is about *the user themselves* (preferences, identity, current state) and no vault fits cleanly → it usually belongs in the personal-knowledge-base vault (often named `me` or similar).

## Edge cases

- **Inbox has unparseable garbage** (e.g., a single misfire dictation like "uhhh"): drop it silently, count in the report under "noise dropped".
- **Inbox has the same thought captured twice on different days**: dedupe into one bullet, note both timestamps in the bullet's source line if useful.
- **Vault's `CLAUDE.md` defines an ingest protocol**: follow that protocol exactly — it overrides anything in this skill.
- **A bullet contradicts an existing wiki page**: trust the bullet (more recent dictation wins over stale wiki), update the page, mention in report.
- **Network/iCloud sync lag**: if `iphone-raw.md` reads as empty but the user insists they dictated something, suggest waiting 30s for iCloud sync and retrying — do not fabricate content.
- **Truncate fails** (file locked by iCloud): retry once after 2s. If it still fails, leave the file alone and report the failure clearly — never partial-clear (partial-clear could lose data on next dictation).

## What not to do

- Do not archive the raw dictation — only summarized bullets land in `archive/`.
- Do not delete `iphone-raw.md` or `ingest.md` (truncate only — the iPhone Shortcut needs `iphone-raw.md` to exist as an append target).
- Do not write to a vault without reading its `CLAUDE.md` first.
- Do not invent metrics, dates, or facts not present in the raw dictation. If transcription is ambiguous, preserve the ambiguity in the bullet rather than guessing.
- Do not exfiltrate dictated content to the network. Everything stays on the local machine and within the user's existing iCloud sync; dictated notes are personal and must never be sent to an external service.
