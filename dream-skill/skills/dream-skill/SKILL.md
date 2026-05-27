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

---

## HARD RULES — read first, apply always

These rules override anything else in this skill. Violating them silently destroys the user's persona-sync.

### Rule 1 — Persistence target is Obsidian vaults ONLY

The ONLY valid write destinations are:
1. Files **inside vault roots** declared in `$DREAM_CONFIG` (via `vault-writer.sh`)
2. The queue file at `$DREAM_QUEUE_FILE` (via `queue.sh`)
3. The daily log at `$DREAM_DAILY_LOG` (plain append)
4. The undo log at `$DREAM_UNDO_LOG` (managed by `vault-writer.sh`)
5. The error log at `$DREAM_ERROR_LOG` (plain append on failures)

You MUST NOT write to any of these:
- ❌ `~/.claude/projects/*/memory/` — that is Claude Code's per-project auto-memory, a different persistence layer. Writing here defeats the whole purpose of dream-skill (which is to sync to the user's GLOBAL Obsidian vault). If you find yourself wanting to use `Edit` or `Write` on `MEMORY.md` or any `user_*.md`, `feedback_*.md`, `project_*.md`, `reference_*.md` file under `~/.claude/projects/`, **STOP** — that file lives in the auto-memory system, not dream-skill's target.
- ❌ Any path outside the vault roots in `$DREAM_CONFIG`
- ❌ Any path not under `$DREAM_HOME`

### Rule 2 — Use the provided helper scripts, never improvise

Vault writes go through `$DREAM_SCRIPTS_DIR/vault-writer.sh`.
Queue appends go through `$DREAM_SCRIPTS_DIR/queue.sh`.
Never use the `Write`/`Edit` tools directly to mutate vault files in auto mode. (Manual mode may use them after explicit user approval.)

### Rule 3 — Fail loud (in the log), exit silent (to the user)

If any required env var (`DREAM_SCRIPTS_DIR`, `DREAM_HOME`, `DREAM_CONFIG`, `DREAM_QUEUE_FILE`) is unset or the path it points to doesn't exist, append a structured error line to `$DREAM_ERROR_LOG` and exit 0. Do NOT try to find an alternative persistence layer. The SessionEnd hook is fire-and-forget; broken installs must surface in `error.log`, never crash, never write to the wrong place.

---

## State layout (env-var sourced)

trigger.sh exports these BEFORE invoking the headless skill. **Always read them from the environment; never hardcode paths.**

| Env var | Default | Purpose |
|---|---|---|
| `DREAM_SCRIPTS_DIR` | (resolved by trigger.sh) | Where vault-writer.sh, queue.sh, apply-undo.sh, preprocess.sh live |
| `DREAM_HOME` | `~/.claude/dream-skill` | Runtime state root |
| `DREAM_CONFIG` | `$DREAM_HOME/config.toml` | Vault roots TOML |
| `DREAM_QUEUE_FILE` | `$DREAM_HOME/queue/pending.md` | Deferred-decision facts |
| `DREAM_DAILY_LOG` | `$DREAM_HOME/log/<YYYY-MM-DD>.md` | Human-readable activity log |
| `DREAM_UNDO_LOG` | `$DREAM_HOME/undo/<YYYY-MM-DD>.jsonl` | Per-write rollback entries |
| `DREAM_ERROR_LOG` | `$DREAM_HOME/error.log` | Append on broken-install failures |
| `DREAM_TRANSCRIPT` | (set by trigger.sh) | Absolute path to the just-closed JSONL transcript |

If any are unset when you enter auto mode, fall through to Rule 3.

## Vault config

`$DREAM_CONFIG` is TOML. Each entry maps a logical vault name to its root directory:

```toml
[vaults.me]
root = "/path/to/me"
description = "Identity, skills, experience, projects, career"

[vaults.projects]
root = "/path/to/projects"
description = "Repos, architecture, goals, gotchas"
```

Each vault root should have a `CLAUDE.md` (the vault's schema/conventions) and `wiki/index.md` (catalog of pages). vault-writer.sh handles index auto-update.

In **auto mode**: if `$DREAM_CONFIG` doesn't exist or has no vault entries, log to `$DREAM_ERROR_LOG` and exit (Rule 3). Do not prompt.

In **manual mode**: if `$DREAM_CONFIG` doesn't exist, prompt the user for at least one vault root and write the file before continuing.

---

## Auto mode (`--auto <transcript-path>`)

**Headless. Never asks user. Never blocks.**

### Step 0 — Sanity check env vars

Confirm `DREAM_SCRIPTS_DIR`, `DREAM_HOME`, `DREAM_CONFIG`, `DREAM_QUEUE_FILE` are all set and the paths exist (the dir for `DREAM_SCRIPTS_DIR` and `DREAM_HOME`, the file for `DREAM_CONFIG`).

Confirm `$DREAM_SCRIPTS_DIR/vault-writer.sh`, `$DREAM_SCRIPTS_DIR/queue.sh`, `$DREAM_SCRIPTS_DIR/preprocess.sh` all exist and are executable.

If any check fails: append one line to `$DREAM_ERROR_LOG` with the timestamp + which check failed, then exit 0.

### Step 1 — Preprocess transcript

Run `$DREAM_SCRIPTS_DIR/preprocess.sh "$DREAM_TRANSCRIPT"` (or the path passed via `--auto`). Capture stdout as `clean_transcript`.

If `clean_transcript` is empty or <5 lines, append `SKIP empty-transcript` to `$DREAM_DAILY_LOG` and exit 0.

### Step 2 — Load vault context

Read `$DREAM_CONFIG` to get vault names + roots.
For each vault, read `<root>/CLAUDE.md` and `<root>/wiki/index.md` (if they exist) to learn schema + catalog. Do **not** read every page — just CLAUDE.md and the index, so you know what exists and where new info would land.

### Step 3 — Extract candidate facts

Scan `clean_transcript`. For each candidate fact, classify into one of these buckets:

#### Bucket A — HIGH CONFIDENCE, ADDITIVE → write to vault

A fact qualifies if ALL of:
- New information about the user (role, project, deadline, preference, decision, relationship, body/health, learning, schedule)
- Vault has no current fact that contradicts it (check the relevant `wiki/index.md` linked pages)
- The user themselves stated it (not the assistant inferring)
- Stated as fact, not hypothesis ("I'm doing X", not "maybe I'll do X")

**Action:** call the helper script with absolute paths:

```bash
"$DREAM_SCRIPTS_DIR/vault-writer.sh" \
  --vault <vault-root-from-config> \
  --page <wiki/page-name.md> \
  --section "<existing or new section header>" \
  --content "<fact text>" \
  --undo-log "$DREAM_UNDO_LOG" \
  --index-label "<short label>" \
  --index-desc "<one-line description>"
```

Then append a `[WRITE] ...` line to `$DREAM_DAILY_LOG`.

#### Bucket B — GENERAL-KNOWLEDGE Q&A → drop UNLESS signal-bearing

If the user asked a generic technical question and got a generic answer, **drop** (log `[DROP] generic Q&A`).

BUT if the question itself reveals user signal — out-of-domain question, surprising knowledge gap, change in focus area — route to queue under `## Brainstormed ideas` as a "user explored X today" note.

#### Bucket C — CODE BLOCKS → drop UNLESS conceptual

If the conversation is pure code-paste/edit loop: **drop** (log `[DROP] code paste, no concept signal`).

BUT if surrounding prose discusses a concept, architecture decision, or pattern the user is learning/choosing, summarize the **concept** (not the code) as a candidate fact and re-run through Bucket A logic.

#### Bucket D — DESTRUCTIVE EDIT → queue

A fact is destructive if it CONTRADICTS or REPLACES existing vault content. Examples: "I'm no longer doing X" (vault still says they do X), "actually it's Y not Z" (vault has Z).

**Action:**

```bash
"$DREAM_SCRIPTS_DIR/queue.sh" append \
  --bucket destructive \
  --title "<short title>" \
  --evidence "<exact quote from transcript>" \
  --confidence <high|medium|low> \
  --target "<vault-relative-path>"
```

Then append `[QUEUE/Destructive] ...` to `$DREAM_DAILY_LOG`.

#### Bucket E — UNCERTAIN or BRAINSTORMED → queue

- Medium/low confidence additive fact → `--bucket uncertain`
- User brainstormed an idea but didn't commit ("maybe I should X", "thinking about Y") → `--bucket brainstormed`

Same call shape as Bucket D, just different `--bucket` value.

### Step 4 — Write the daily log

Append (don't overwrite) to `$DREAM_DAILY_LOG`. Suggested format:

```markdown
## <YYYY-MM-DDTHH:MM:SSZ> auto run — transcript <basename>

- [WRITE] <vault>/<page>: added "<short summary>"
- [QUEUE/Destructive] <short title> → contradicts <vault>/<page>
- [QUEUE/Brainstormed] <short title>
- [DROP] <reason>

Summary: X writes, Y queued, Z dropped.
```

### Step 5 — Exit silently

Never print to stdout in auto mode (headless invocation may discard it). All output goes to log files. Exit 0 even on partial failures so the SessionEnd hook stays fire-and-forget.

---

## Manual mode (no args)

**Interactive. Walks the user through the queue fact-by-fact.**

### Step 1 — Read queue

Open `$DREAM_QUEUE_FILE`. Parse into entries (one per `### ` heading inside any `## <bucket>` section).

If empty: tell user "Queue is empty. Nothing to review." and exit.

### Step 2 — Present each entry

For each entry, show:

```
[N/M] <bucket>: <title>

Evidence:
  "<quote>"

Proposed target: <vault>/<page>
Confidence: <high|medium|low>

[a]pprove  [e]dit  [s]kip  [d]iscard  [q]uit
```

Wait for user input.

### Step 3 — Act on choice

- **approve**: call `vault-writer.sh` with the entry's params, append undo entry, remove entry from `$DREAM_QUEUE_FILE`.
- **edit**: prompt user for new content (display current as default), then either re-classify (re-run through buckets) and apply, OR re-queue with updated text. Confirm before writing.
- **skip**: leave in queue, advance to next entry.
- **discard**: remove entry from queue without writing.
- **quit**: stop walking; remaining entries stay queued.

### Step 4 — Summary

When walked through all entries (or user quits), print:

```
Dream queue review complete.
- Approved: X
- Edited: Y
- Discarded: Z
- Skipped (still queued): W
```

---

## Reconcile mode (`--reconcile`)

**Reserved for v0.3.** Print:

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
- `hooks/hooks.json` — SessionEnd hook
- `scripts/trigger.sh` — exports all `DREAM_*` env vars before invoking headless mode
- `scripts/preprocess.sh` — transcript noise stripper (handles real Claude Code nested format + flat format)
- `scripts/vault-writer.sh` — add-only vault append + idempotent index update
- `scripts/queue.sh` — queue file manager (append + list + dedupe by title+target)
- `scripts/apply-undo.sh` — rollback auto-mode writes
- `scripts/count_tokens.py` — tiktoken counter (cost guard, future use)
