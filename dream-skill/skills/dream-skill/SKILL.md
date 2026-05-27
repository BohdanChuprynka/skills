---
name: dream-skill
description: Auto-record Claude Code conversations to an Obsidian vault. Use when the user says "/dream-skill", "review dream queue", "process dream queue", "sweep dream queue", or asks to update wiki from a recent conversation. Also runs headlessly via SessionEnd hook in auto mode when invoked with `--auto <transcript-path>`. Manual no-arg invocation sweeps the queue of deferred-decision facts and walks the user through approve/edit/skip. `--reconcile` is a v0.3 stub.
version: 0.2.0
---

# dream-skill

Persona-model sync for an Obsidian vault. Three modes:

| Invocation | Mode | Trigger |
|---|---|---|
| `/dream-skill --auto <transcript.jsonl>` | **Auto (headless)** | SessionEnd hook fires this on close. No user interaction. |
| `/dream-skill` (no args) | **Manual review** | User runs this anytime to walk the queue. |
| `/dream-skill --reconcile` | **Reconcile (stub)** | Reserved for v0.3 full-vault audit. Prints "not yet implemented" and exits. |

## State layout

All dream-skill runtime state lives under `~/.claude/dream-skill/`:

```
~/.claude/dream-skill/
├── trigger.log                # SessionEnd dispatch decisions (one line per session close)
├── headless.log               # stdout/stderr from spawned claude -p runs
├── log/
│   └── <YYYY-MM-DD>.md        # human-readable auto-write log per day
├── undo/
│   └── <YYYY-MM-DD>.jsonl     # per-write rollback entries (one JSONL line per fact written)
├── queue/
│   └── pending.md             # deferred-decision facts awaiting manual review
└── config.toml                # vault roots, page conventions (auto-created on first run)
```

The queue (`queue/pending.md`) survives plugin updates and reinstalls.

## Vault config

If `~/.claude/dream-skill/config.toml` doesn't exist, prompt the user (manual mode only) for vault root(s) and write a default config. In auto mode, if config is missing, log an error to `trigger.log` and exit gracefully — never block.

Default config shape:

```toml
[vaults.me]
root = "/Users/bohdan/Documents/IT-Work/Projects/IT/Obsidian/me"
description = "Identity, skills, experience, projects, career"

[vaults.projects]
root = "/Users/bohdan/Documents/IT-Work/Projects/IT/Obsidian/projects"
description = "Repositories, architecture, goals, gotchas"
```

Each vault root must have a `CLAUDE.md` (schema) and `wiki/index.md` (catalog) — same convention as the user's existing setup.

---

## Auto mode (`--auto <transcript-path>`)

**Runs headlessly. Never asks user. Never blocks.**

### Step 1 — Preprocess transcript

Run `${CLAUDE_PLUGIN_ROOT}/scripts/preprocess.sh <transcript-path>` to strip tool calls, tool results, system reminders, MCP raw output, hook content. Capture stdout as `clean_transcript`.

If `clean_transcript` is empty or <5 lines, log `SKIP empty-transcript` to `~/.claude/dream-skill/log/<date>.md` and exit 0.

### Step 2 — Load vault context

Read each vault's `CLAUDE.md` and `wiki/index.md` to understand schema and existing pages. Do **not** read every page — just the index, so you know what exists and where new info would land.

### Step 3 — Extract candidate facts

Scan `clean_transcript` line-by-line. For each candidate fact, classify into one of these buckets:

#### Bucket A — HIGH CONFIDENCE, ADDITIVE → write to vault

A fact is high-confidence-additive if ALL of:
- New information about the user (role, project, deadline, preference, decision, relationship, body/health, learning, schedule)
- Vault has no current fact that contradicts it
- The user themselves stated it (not the assistant inferring)
- Stated as fact, not hypothesis ("I'm doing X", not "maybe I'll do X")

Action: call `${CLAUDE_PLUGIN_ROOT}/scripts/vault-writer.sh` with `--vault`, `--page`, `--section`, `--content`, `--undo-log` args. Append entry to `log/<date>.md` and `undo/<date>.jsonl`.

#### Bucket B — GENERAL-KNOWLEDGE Q&A → drop unless signal-bearing

If user asked a generic technical question and got a generic answer, drop. BUT if the question itself reveals user signal — out-of-domain question ("I'm an AI engineer asking about FDA reg pathways" → learning happening), surprising knowledge gap, change in focus area — route to queue under `## Brainstormed ideas` or relevant signal bucket as **Bucket E**.

#### Bucket C — CODE BLOCKS → drop unless conceptual

If the conversation is a pure code-paste/edit loop, drop. BUT if the surrounding prose discusses a concept, architecture decision, or pattern the user is learning/choosing, summarize the **concept** (not the code) as a candidate fact and run through Bucket A logic.

#### Bucket D — DESTRUCTIVE EDIT → queue

A fact is destructive if it CONTRADICTS or REPLACES existing vault content. Examples: "I'm no longer doing X" (vault still says they do X), "actually it's Y not Z" (vault has Z).

Action: append to `~/.claude/dream-skill/queue/pending.md` under `## Destructive edits` section. Use the proposal-evidence-confidence schema:

```markdown
### <short title>

**Bucket:** Destructive
**Evidence:**
- "<exact quote from transcript>" (session: <transcript-filename>)

**Vault says:** `<file>:<lineN>` — "<current text>"
**Transcript says:** "<new text>"
**Confidence:** medium
**Action:** replace/remove
**Target:** <vault-relative-path>

---
```

#### Bucket E — UNCERTAIN / BRAINSTORMED → queue

If confidence is medium/low, or the user brainstormed an idea without committing to it ("maybe I should X", "I'm thinking about Y"), route to queue.

Sub-buckets in `pending.md`:
- `## Uncertain facts` — medium confidence, additive
- `## Brainstormed ideas` — user explored an idea, didn't decide (track for future follow-up)

Same schema as Bucket D, with `**Bucket:** Uncertain` or `**Bucket:** Brainstormed`.

### Step 4 — Write the daily log

For each fact processed in Steps 3:

```markdown
## <YYYY-MM-DDTHH:MM:SSZ>

- [WRITE] <vault>/<page>: added "<short summary>" → undo entry #<N>
- [QUEUE/Destructive] <short title> → contradicts <vault>/<page>
- [QUEUE/Brainstormed] <short title>
- [DROP] <reason>
```

Append (don't overwrite) to `~/.claude/dream-skill/log/<YYYY-MM-DD>.md`.

### Step 5 — Exit silently

Never print to stdout in auto mode (headless invocation may discard or log it). All output goes to log files. Exit 0 even on errors so the SessionEnd hook stays fire-and-forget.

---

## Manual mode (no args)

**Interactive. Walks the user through the queue fact-by-fact.**

### Step 1 — Read queue

Open `~/.claude/dream-skill/queue/pending.md`. Parse into entries.

If empty: tell user "Queue is empty. Nothing to review." and exit.

### Step 2 — Present each entry

For each entry, show:

```
[N/M] <bucket>: <title>

Evidence:
  "<quote>" (session: <session-id>)

Proposed action: <action>
Target: <vault>/<page>

[a]pprove  [e]dit  [s]kip  [d]iscard  [q]uit
```

Wait for user input.

### Step 3 — Act on choice

- **approve**: call `vault-writer.sh` with the entry's params, append undo entry, remove from queue.
- **edit**: open the entry's content in a temporary edit prompt; on save, re-classify and either apply or re-queue.
- **skip**: leave in queue, move to next entry.
- **discard**: remove from queue without writing.
- **quit**: stop walking, leave remaining entries in queue.

### Step 4 — Summary

When walked through all entries (or user quits), print summary:

```
Dream queue review complete.
- Approved: X
- Edited: Y
- Discarded: Z
- Skipped (still queued): W
```

---

## Reconcile mode (`--reconcile`)

**Reserved for v0.3.** Print to stdout:

```
/dream-skill --reconcile is not yet implemented in v0.2.

v0.2 ships per-conversation auto-capture via SessionEnd hook.
v0.3 will add scheduled full-vault audit against accumulated session data.

For now, run /dream-skill (no args) to review the queue.
```

Exit 0.

---

## Cross-references

- `HARVEST.md` — patterns ported from v0.1
- `PLAN.md` — v0.2 build plan
- `hooks/hooks.json` — the SessionEnd hook that drives auto mode
- `scripts/trigger.sh` — gates dispatch on message count
- `scripts/preprocess.sh` — transcript noise stripper
- `scripts/vault-writer.sh` — add-only vault append + index update (Phase 4)
- `scripts/queue.sh` — queue file management (Phase 4)
- `scripts/apply-undo.sh` — rollback auto-mode writes (Phase 4)
