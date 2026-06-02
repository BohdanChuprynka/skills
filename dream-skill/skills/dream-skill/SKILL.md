---
name: dream-skill
description: Auto-record Claude Code conversations to an Obsidian vault. Use when the user says "/dream-skill", "review dream queue", "process dream queue", "sweep dream queue", or asks to update wiki from a recent conversation. Also runs headlessly via SessionEnd hook in auto mode when invoked with `--auto <transcript-path>`. Manual no-arg invocation sweeps the queue of deferred-decision facts and walks the user through approve/edit/skip. `--reconcile` is a v0.3 stub. Type `/dream-skill --ignore` to mark the current chat private so it is never recorded into the vault (undo with `--unignore`).
version: 0.2.0
---

# dream-skill

Persona-model sync for an Obsidian vault. Four modes:

| Invocation | Mode | Trigger |
|---|---|---|
| `/dream-skill --auto <transcript.jsonl>` | **Auto (headless)** | SessionEnd hook fires this on close. No user interaction. |
| `/dream-skill` (no args) | **Manual review** | User runs this anytime to walk the queue. |
| `/dream-skill --ignore` | **Mark private** | User runs this in a chat they don't want recorded. Confirms; the SessionEnd hook then skips this chat on close. |
| `/dream-skill --unignore` | **Unmark private** | Undo `--ignore` for this chat — recording resumes on close. |
| `/dream-skill --reconcile` | **Reconcile (stub)** | Reserved for v0.3 full-vault audit. Prints "not yet implemented" and exits. |
| `/dream-skill --help` | **Help** | Prints the mode table, env vars, state paths, and exits. Never writes anything. |

### `--help` output

When invoked with `--help` (or `-h`), print this verbatim and exit 0:

```
dream-skill v0.2 — auto-record Claude Code conversations to an Obsidian vault.

USAGE
  /dream-skill                          Manual queue review (interactive)
  /dream-skill --ignore                  Mark THIS chat private — never recorded
  /dream-skill --unignore                Undo --ignore for this chat
  /dream-skill --auto <transcript.jsonl> Headless capture (used by SessionEnd hook)
  /dream-skill --reconcile               v0.3 stub — prints not-implemented
  /dream-skill --help                    Show this help

STATE
  ~/.claude/dream-skill/config.toml       Vault roots
  ~/.claude/dream-skill/queue/pending.md  Deferred-decision facts (review with no-arg call)
  ~/.claude/dream-skill/log/<date>.md     Daily human-readable activity log
  ~/.claude/dream-skill/undo/<date>.jsonl Per-write rollback entries
  ~/.claude/dream-skill/trigger.log       SessionEnd dispatch decisions
  ~/.claude/dream-skill/error.log         Append on broken-install failures

ENV VARS (set by trigger.sh before headless run)
  DREAM_SCRIPTS_DIR   Resolved scripts/ dir (vault-writer.sh, queue.sh, ...)
  DREAM_HOME          Defaults to ~/.claude/dream-skill
  DREAM_CONFIG        Path to config.toml
  DREAM_QUEUE_FILE    Path to queue/pending.md
  DREAM_DAILY_LOG     Path to today's log file
  DREAM_UNDO_LOG      Path to today's undo file
  DREAM_ERROR_LOG     Path to error log
  DREAM_TRANSCRIPT    Absolute path to the just-closed transcript

ROLLBACK
  bash $DREAM_SCRIPTS_DIR/apply-undo.sh --date <YYYY-MM-DD>

DOCS
  README.md, HARVEST.md, PLAN.md in the plugin root.
```

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

### Rule 4 — Always close the trigger.log loop

Every auto-mode invocation MUST end with a `COMPLETED` or `ERROR` line appended to `$DREAM_LOG` (see Step 6). trigger.sh logged a `SPAWNED` line right before invoking you; `check-pending.sh` treats unmatched `SPAWNED` lines as silent failures and writes a `WARNING kind=orphan` line. If you skip Step 6, the log gets spurious orphan warnings — which means YOU are the source of the noise the user sees on `tail trigger.log`.

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
| `DREAM_LOG` | `$DREAM_HOME/trigger.log` | Append-only dispatch decisions + completion markers (Step 6) |

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

### Step 0 — Sanity check env vars (literal file checks ONLY)

This is a **plain `test -f` / `test -d` check on shell env vars and paths**. It is NOT a check of which tools you have access to or which permissions you've been granted. Do not abort on tool-availability concerns or permission concerns. Run the checks via `Bash` tool only:

```bash
[ -n "$DREAM_SCRIPTS_DIR" ] && [ -d "$DREAM_SCRIPTS_DIR" ] || echo "MISSING DREAM_SCRIPTS_DIR" >> "$DREAM_ERROR_LOG"
[ -n "$DREAM_HOME" ]        && [ -d "$DREAM_HOME" ]        || echo "MISSING DREAM_HOME"        >> "$DREAM_ERROR_LOG"
[ -n "$DREAM_CONFIG" ]      && [ -f "$DREAM_CONFIG" ]      || echo "MISSING DREAM_CONFIG"      >> "$DREAM_ERROR_LOG"
[ -x "$DREAM_SCRIPTS_DIR/vault-writer.sh" ] || echo "MISSING vault-writer.sh" >> "$DREAM_ERROR_LOG"
[ -x "$DREAM_SCRIPTS_DIR/queue.sh" ]        || echo "MISSING queue.sh"        >> "$DREAM_ERROR_LOG"
[ -x "$DREAM_SCRIPTS_DIR/preprocess.sh" ]   || echo "MISSING preprocess.sh"   >> "$DREAM_ERROR_LOG"
[ -x "$DREAM_SCRIPTS_DIR/preprocess-gate.sh" ] || echo "MISSING preprocess-gate.sh" >> "$DREAM_ERROR_LOG"
```

If — and ONLY if — any file/dir literally does not exist on disk: append the failure to `$DREAM_ERROR_LOG` and exit 0. Otherwise, proceed to Step 1.

**You are running under `--dangerously-skip-permissions`. You will not be prompted for any tool call. Do not abort because you "might not have permission" — you do.**

### Step 0.5 — Honor the private opt-out (belt-and-suspenders)

`trigger.sh` already skips chats the user marked private *before* spawning you. In rare paths (e.g. compaction-continuation resolution) you may still be invoked on one — so re-check the **raw** transcript (not the preprocessed text; command records may be stripped):

```bash
"$DREAM_SCRIPTS_DIR/private-state.sh" "$DREAM_TRANSCRIPT"
```

If it prints `ignore`, the user typed `/dream-skill --ignore`: write NOTHING to the vault or queue. Close the loop and exit 0:

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS COMPLETED source=skill reason=marked-private writes=0 queued=0 dropped=0 transcript=$DREAM_TRANSCRIPT" >> "$DREAM_LOG"
"$DREAM_SCRIPTS_DIR/report.sh" --status skipped \
  --chat "${DREAM_CHAT_LABEL:-$(basename "${DREAM_TRANSCRIPT%.jsonl}") (auto)}" \
  --reason "marked private" 2>/dev/null || true
```

Pass **no** `--title` — the first message is itself sensitive. Then stop (do not run Steps 1–6).

### Step 1 — Preprocess transcript (deterministic content gate)

Run the content gate and decide OK/EMPTY/ERROR **from its exit code alone**. **You MUST NOT inspect the cleaned text's length or content to judge whether the transcript is "empty."** That exact judgment call is the v0.2 bug: a rich 5.8 KB session was eyeballed, called "empty after preprocessing," and silently dropped. `preprocess-gate.sh` makes emptiness a deterministic byte-count decided in-shell, surfaced as an exit code:

- exit `0` = **OK** — real content; the cleaned text is on stdout (your `clean_transcript`)
- exit `3` = **EMPTY** — valid transcript, but nothing survives cleaning
- exit `2` = **ERROR** — missing / unreadable / corrupt transcript, or `jq` unavailable

Bind `T` to the transcript path: **it is the path in your `--auto` argument** — e.g. if you were invoked as `/dream-skill --auto /Users/me/.claude/projects/x/abc.jsonl`, set `T=/Users/me/.claude/projects/x/abc.jsonl` (substitute the real path; do not leave a placeholder). `$DREAM_TRANSCRIPT` holds the same path as a fallback. Then capture **set-e-safely** — a bare `clean=$(…); rc=$?` aborts before `rc=$?` under `set -e`:

```bash
T="/absolute/path/from/your/--auto/argument.jsonl"   # the real path; $DREAM_TRANSCRIPT is the same value
[ -f "$T" ] || T="$DREAM_TRANSCRIPT"
if clean_transcript=$("$DREAM_SCRIPTS_DIR/preprocess-gate.sh" "$T" 2>>"$DREAM_ERROR_LOG"); then
  :   # OK (exit 0): real content is in $clean_transcript → go to Step 2
else
  rc=$?   # 3 = EMPTY, 2 (or any other non-zero) = ERROR
fi
```

Then branch on the result:

- **OK** → proceed to Step 2 with `$clean_transcript`.
- **EMPTY (`rc` = 3)** → genuinely nothing to ingest. Append `[SKIP] empty-transcript` to `$DREAM_DAILY_LOG`, then close the loop via **Step 6** with `reason=empty-transcript` (report `--status noop --reason empty-transcript`). Exit 0.
- **ERROR (`rc` ≠ 0 and ≠ 3)** → the transcript is missing/unreadable/corrupt. Do **not** report it as empty. Append the failure to `$DREAM_ERROR_LOG`, then close the loop via **Step 6** ERROR branch (`--status error`). Exit 0.

Do **not** skip on length alone: a single short user message can be high persona signal (e.g. "I got into MIT", "quit my job today"). If the gate says OK, there is content — process it.

### Step 2 — Load vault context

Read `$DREAM_CONFIG` to get vault names + roots.
For each vault, read `<root>/CLAUDE.md` and `<root>/wiki/index.md` (if they exist) to learn schema + catalog. Do **not** read every page — just CLAUDE.md and the index, so you know what exists and where new info would land.

### Step 3 — Extract candidate facts

Scan `clean_transcript`. For each candidate fact, classify into one of these buckets.

**Meta-session rule (important):** If the transcript is about building/debugging dream-skill itself, do NOT blanket-skip as "recursive." Look for concrete decisions the user made: architecture picks, file paths committed to, technical choices, version bumps, default values changed. Those ARE persona signal about their work and belong in vault (typically `projects/wiki/skills-monorepo.md` or similar). Only skip the literal back-and-forth ("yes", "do it", "looks good") as Bucket B execution-confirmations.

#### Bucket A — HIGH CONFIDENCE, ADDITIVE → write to vault

**Default to WRITE, not queue.** Auto-mode's whole purpose is to keep the vault current without manual sync. Queue is an escape hatch for genuinely ambiguous facts, NOT the default. If you find yourself queuing 5+ facts in one run and writing 0, you are being too cautious — re-classify.

A fact qualifies as Bucket A if ALL of:
- New information about the user OR about a project/topic the user is working on (role, project, deadline, preference, decision, relationship, body/health, learning, schedule, technical choice, architecture pick)
- Vault has no current fact that contradicts it (check the relevant `wiki/index.md` linked pages)
- The user themselves stated it OR the assistant stated it and the user confirmed (acceptance, "yes", "do it", building on it)
- Stated as fact or decision, not pure hypothesis ("I'm doing X" / "let's go with X" qualifies; "maybe I'll do X" does not)

**Concrete qualifying examples** (write these, don't queue):
- User picks a tech stack ("we're using Postgres + Drizzle")
- User commits to a project direction ("v0.2 will ship Haiku as default model")
- User states a date or deadline ("Cycle 4 ends 2026-08-17")
- User defines a workflow ("close session → SessionEnd → headless")
- User makes an architecture call ("use add-only writes + queue for destructive")

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

### Step 6 — Record completion to $DREAM_LOG

ALWAYS run this as the **final action** of auto mode, regardless of which exit branch you took. Without it, `check-pending.sh` will see your `SPAWNED` line as an orphan on the next session start and append a false-alarm `WARNING` line to the log.

Append exactly ONE line to `$DREAM_LOG` (NOT to `$DREAM_DAILY_LOG` — that's a different file for human-readable summaries).

**On successful or legitimate-skip completion** (Step 4 normal completion / Step 1 empty / Step 3 recursive / Step 3 no-info):

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS COMPLETED source=skill reason=<reason> writes=<N> queued=<N> dropped=<N> transcript=$DREAM_TRANSCRIPT" >> "$DREAM_LOG"
```

`<reason>` enum (pick one):
- `wrote-N` — Step 4 normal completion (N is total `[WRITE]` count)
- `empty-transcript` — Step 1 stripped output was empty (no content after cleaning)
- `recursive-transcript` — Step 3 every line was a dream-skill discussion
- `no-info-gain` — Step 3 candidates extracted but all dropped (Bucket B/C)
- `marked-private` — Step 0.5 user marked this chat private (`/dream-skill --ignore`)

**On internal ERROR** (Step 0 env validation failed, vault-writer.sh non-zero, any unhandled error):

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS ERROR source=skill code=1 msg=\"<short msg>\" transcript=$DREAM_TRANSCRIPT" >> "$DREAM_LOG"
```

**Then write the user-visible vault entry.** Same final action — this is what the user sees in Obsidian under `dream-reports/dream-<date>.md`. It uses `$DREAM_CHAT_LABEL` (exported by trigger.sh) and `$DREAM_SCRIPTS_DIR/report.sh`. Run exactly ONE branch, matching the `$DREAM_LOG` outcome you just recorded. It is best-effort: never let a report failure change your exit status.

```bash
LABEL="${DREAM_CHAT_LABEL:-$(basename "${DREAM_TRANSCRIPT%.jsonl}") (auto)}"
TITLE="${DREAM_CHAT_TITLE:-}"   # first-message title (empty → report.sh omits the title: line)
```

- **wrote** — pipe the SAME `[WRITE]/[QUEUE]/[DROP]` lines you appended to `$DREAM_DAILY_LOG` in Step 4 (omit the `## ...` header and the `Summary:` line):

```bash
"$DREAM_SCRIPTS_DIR/report.sh" --status wrote --chat "$LABEL" --title "$TITLE" <<'BODY' 2>/dev/null || true
- [WRITE] me/wiki/<page>.md: <short summary>
- [DROP] <reason>
BODY
```

- **noop** — nothing written; `<reason>` is `empty-transcript` | `recursive-transcript` | `no-info-gain`:

```bash
"$DREAM_SCRIPTS_DIR/report.sh" --status noop --chat "$LABEL" --title "$TITLE" --reason "<reason>" 2>/dev/null || true
```

- **error**:

```bash
"$DREAM_SCRIPTS_DIR/report.sh" --status error --chat "$LABEL" --title "$TITLE" --reason "see error.log" 2>/dev/null || true
```

This is the contract that lets the user see silent failures. If you skip Step 6, the next-session orphan scanner produces a spurious `WARNING` line. **Always close the loop.**

---

## Manual mode (no args)

**Interactive. Walks the user through the queue fact-by-fact in the REPL.**

### Step 1 — Read queue

Open `$DREAM_QUEUE_FILE`. Parse into entries (one per `### ` heading inside any `## <bucket>` section). Each entry has 5 fields: `bucket`, `title`, `evidence`, `confidence`, `target`.

If empty: tell user `Queue is empty. Nothing to review.` and exit 0.

### Step 2 — Present each entry

Show the entry verbatim:

```
[N/M] <bucket>: <title>

  Evidence:   "<quote>"
  Target:     <vault-relative-path>
  Confidence: <high|medium|low>

[a]pprove  [e]dit  [s]kip  [d]iscard  [q]uit
```

Wait for user input.

### Step 3 — Act on choice

#### approve (`a`)

1. Resolve `target` to a configured vault: look up `vaults.<name>.root` in `$DREAM_CONFIG` where `<name>` is the first path segment of `target` (e.g., `me/wiki/Bio.md` → `vaults.me`). If no match, prompt user to pick a vault.
2. Ask user for two missing fields the queue entry doesn't carry:
   - `section` (default: `Notes`)
   - `content` (default: the entry's `title`)
   Show both as a one-line preview: `Will write to <vault>/<page> under "## <section>": "- <content>"`. Wait for `[c]onfirm` or `[c]ancel`.
3. On confirm: call `vault-writer.sh` with the resolved args + `--undo-log "$DREAM_UNDO_LOG"`. Then call `queue.sh remove --title "<title>" --target "<target>"` to clear the entry.
4. Append `[APPROVED] <vault>/<page>: <content>` to `$DREAM_DAILY_LOG`.

#### edit (`e`) — free-form field editor

Prompt: `What to edit? Comma-separated field:value pairs. Valid fields: title, evidence, target, confidence, bucket. Example: title: Move to Acme, target: me/wiki/Work.md`

Parse the user's input by splitting on `,` then on the first `:` per pair. Trim whitespace. Validate:
- `bucket` must be one of `destructive`, `uncertain`, `brainstormed` (reject + re-prompt if not)
- `confidence` must be one of `high`, `medium`, `low`
- Unknown field names → tell user `unknown field: X (valid: title, evidence, target, confidence, bucket)` and re-prompt

Apply edits to an in-memory copy of the entry. Re-show the FULL updated entry verbatim (same shape as Step 2, no diff highlighting — just the new values). Prompt: `[a]pply  [r]e-edit  [d]iscard`.

- **apply (`a`)**: Persist the edits to the queue:
  - `queue.sh remove --title "<original-title>" --target "<original-target>"` (use the ORIGINAL title/target, since those identify the entry)
  - `queue.sh append --bucket "<new-bucket>" --title "<new-title>" --evidence "<new-evidence>" --confidence "<new-confidence>" --target "<new-target>"`
  - This works whether the bucket changed or not — remove + append is the same primitive
  - Then continue to the next entry (do NOT auto-approve after edit — user must explicitly approve a separately-edited entry on the next pass)
- **re-edit (`r`)**: discard the current in-memory edits, re-prompt for changes from the original entry.
- **discard (`d`)**: drop the edits, leave the entry untouched in queue, advance to next.

#### skip (`s`)

Leave the entry in queue. Advance.

#### discard (`d`)

Call `queue.sh remove --title "<title>" --target "<target>"`. Advance. Append `[DISCARDED] <title>` to `$DREAM_DAILY_LOG`.

#### quit (`q`)

Stop walking. Remaining entries stay queued. Jump to Step 4.

### Step 4 — Summary

Print:

```
Dream queue review complete.
- Approved: X
- Edited:   Y  (still queued; review again to approve)
- Discarded: Z
- Skipped (still queued): W
```

Append a summary line to `$DREAM_DAILY_LOG`.

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

## Private opt-out mode (`--ignore` / `--unignore`)

**Interactive, confirmation-only. Writes nothing — the skip is enforced at close.**

When invoked as `/dream-skill --ignore`: do NOT process the queue or touch the vault. Print exactly this, then exit 0:

> 🔒 This chat is now private. dream-skill will **skip it** when you close it — nothing from this conversation will be written to your Obsidian vault. Undo anytime with `/dream-skill --unignore`.

When invoked as `/dream-skill --unignore`: print exactly this, then exit 0:

> 🔓 This chat is no longer private. dream-skill will record it on close as usual.

**How it works:** typing the command leaves a record in the transcript. At close, the SessionEnd hook (`trigger.sh` → `private-state.sh`) reads the LATEST `--ignore`/`--unignore` and, when the chat is private, skips dispatch entirely — no model tokens are spent, and a `skipped — marked private` line (no chat content, no title) lands in your `dream-reports/dream-<date>.md`. Decision is latest-wins and covers the whole chat.

---

## Cross-references

- `HARVEST.md` — patterns ported from v0.1
- `PLAN.md` — v0.2 build plan
- `hooks/hooks.json` — SessionEnd hook
- `scripts/trigger.sh` — exports all `DREAM_*` env vars before invoking headless mode
- `scripts/preprocess.sh` — transcript noise stripper (handles real Claude Code nested format + flat format)
- `scripts/vault-writer.sh` — add-only vault append + idempotent index update
- `scripts/queue.sh` — queue file manager (append + list + dedupe by title+target)
- `scripts/private-state.sh` — resolves a chat's private (`--ignore`) state from its transcript (used by trigger.sh + auto mode)
- `scripts/apply-undo.sh` — rollback auto-mode writes
- `scripts/count_tokens.py` — tiktoken counter (cost guard, future use)
