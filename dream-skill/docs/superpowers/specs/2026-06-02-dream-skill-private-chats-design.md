# Design: private-chat opt-out for dream-skill (`/dream-skill --ignore`)

- **Date:** 2026-06-02
- **Status:** approved — ready for implementation planning
- **Component:** dream-skill plugin (`scripts/trigger.sh`, `skills/dream-skill/SKILL.md`, docs, tests)

## Problem

dream-skill auto-records every Claude Code conversation to the user's Obsidian
vault: the `SessionEnd` hook runs `scripts/trigger.sh`, which dispatches a
headless capture run whenever a transcript has ≥1 genuine user message and new
content since the last dispatch. There is **no way to exclude a single chat**.
When a conversation is personal, the user must either let it be recorded or
never close it. The user wants a low-friction way to say "this chat is private —
do not record it" and have closing it skip recording.

## Goals

- A user can mark the **current chat** private with a single, easy-to-type
  command and trust that closing it writes nothing to the vault.
- The exclusion is enforced as a **hard skip at dispatch time** (before any model
  tokens are spent), not a soft "the capture model hopefully drops it."
- Reversible: a chat marked private can be un-marked (`--unignore`).
- The skip is **visible** (the user can confirm it happened) without leaking
  conversation content.
- **Ships entirely inside the plugin.** No requirement for the user to edit a
  global `CLAUDE.md` or any external config — anyone who installs the plugin gets
  the feature.

## Non-goals

- No per-project / per-folder denylist (out of scope; this is per-chat).
- No bespoke `SessionStart` context-injection hook (see "Discoverability" — we use
  the skill's own `description:` instead).
- No automatic model-driven "this looks personal, I'll skip it" classification.
  Exclusion is an explicit user action.

## Mechanism

The user types `/dream-skill --ignore` in the chat they want excluded (and
`/dream-skill --unignore` to undo). Detection keys on the fact that **Claude Code
serializes every typed slash command, with its arguments, into the transcript
`.jsonl`** as a single message whose content contains:

```
<command-name>/dream-skill</command-name>
<command-message>dream-skill</command-message>
<command-args>--ignore</command-args>
```

This was verified empirically against the user's existing transcripts
(`~/.claude/projects/**/*.jsonl`): `<command-name>/dream-skill</command-name>`
appears 408×, and arguments persist verbatim, e.g.
`<command-args>--auto /Users/.../xxx.jsonl</command-args>`. The three tags live in
the **same message content string** (one physical `.jsonl` line, with `\n` stored
as the literal 2-character escape).

### Why this signal is robust

1. **Created by Claude Code, not the model.** The instant the user types the
   command, Claude Code writes the `<command-args>` record — independent of
   whatever the skill does afterward. So the guarantee does not depend on the
   model behaving correctly.
2. **Self-trigger-proof.** Detection requires the `--ignore` flag to appear
   *inside a `<command-args>` tag paired with the dream-skill command-name*. Every
   place that merely *mentions* the flag as prose — the `--help` text, the README,
   the skill `description:` (which is loaded into every session's skill catalog and
   therefore lands in every transcript), the auto-mode instructions — is plain
   text and **cannot** match. This is the load-bearing invariant: **never grep a
   bare `--ignore`; always require the `<command-args>` tag.**

We therefore **drop the earlier HTML-comment marker idea entirely** — the command
serialization is a cleaner, lower-friction signal.

## Components

### 1. `scripts/trigger.sh` — private gate (the hard guarantee)

Add a new gate **after** the recursion guard and the `clear|prompt_input_exit`
reason-skip, and **before** the genuine-user-message count (so even a one-message
private chat is skipped without bothering to count).

Latest-wins logic over the resolved `$TRANSCRIPT` (the gate runs after the
compaction-continuation resolution, so it inspects the live root transcript where
the user actually typed the command):

```bash
# --- private opt-out gate (latest-wins) ---------------------------------
# A user can mark THIS chat private by typing `/dream-skill --ignore`, and undo
# it with `/dream-skill --unignore`. Claude Code records each typed slash command
# (with args) into the transcript as a <command-args>…</command-args> record, so
# we detect intent by scanning for the LAST such toggle. We require the flag to
# sit inside a <command-args> tag paired with the dream-skill command-name; prose
# that merely mentions the flag (help text, skill description, this comment) is
# NOT inside that tag and can never match — this is what prevents self-triggering.
TOGGLE_RE='<command-name>/dream-skill</command-name>.*<command-args>[^<]*--(un)?ignore'
LAST_TOGGLE="$(grep -aE "$TOGGLE_RE" "$TRANSCRIPT" 2>/dev/null | tail -1 || true)"
if [ -n "$LAST_TOGGLE" ] && ! printf '%s' "$LAST_TOGGLE" | grep -q -- '--unignore'; then
  log "SKIP private transcript=$TRANSCRIPT"
  "$REPORT_SH" --status skipped \
               --chat "$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")" \
               --reason "marked private (/dream-skill --ignore)" 2>/dev/null || true
  exit 0
fi
```

Notes:
- `grep | tail -1` returns the last matching physical line = the latest invocation
  in chronological order (the `.jsonl` is append-only).
- `--ignore` is **not** a substring of `--unignore`, so the two are unambiguous;
  the regex `--(un)?ignore` matches both, and the `! grep -q -- '--unignore'` test
  decides which the latest one was.
- **No `--title`** is passed to `report.sh` — the chat title is the user's first
  message, which for a private chat is itself sensitive. (`report.sh` already omits
  the `title:` line when `--title` is empty/absent.)
- This gate writes **no** `SEEN_FILE` and does not dispatch, so removing the
  `--ignore` later (via `--unignore`) lets the normal new-content gate dispatch as
  usual.

### 2. `skills/dream-skill/SKILL.md` — `--ignore` / `--unignore` modes

Add two modes to the interactive surface. Both are **confirmation-only**: they do
not read/write the vault or queue. The privacy enforcement lives entirely in
`trigger.sh` (#1); these modes exist to give the user immediate feedback and to be
the thing they invoke.

- `--ignore` (alias: when present, short-circuit before any other mode logic):
  print exactly, then exit 0:
  > 🔒 This chat is now private. dream-skill will **skip it** when you close it —
  > nothing from this conversation will be written to your Obsidian vault. Undo
  > anytime with `/dream-skill --unignore`.

- `--unignore`: print exactly, then exit 0:
  > 🔓 This chat is no longer private. dream-skill will record it on close as
  > usual.

Also update:
- The **mode table** at the top of SKILL.md (add both rows).
- The **`--help`** output block (add both usage lines + a one-line explanation).
- The **`description:` frontmatter** — this is the discoverability mechanism
  (replaces a SessionStart hook). Append something like: *"Type `/dream-skill
  --ignore` to mark the current chat private so it is never recorded (undo with
  `--unignore`)."* Because the skill catalog is loaded every session, Claude can
  then suggest the command when the user asks not to save a conversation — at zero
  extra per-session cost. (Safe: this is prose, not a `<command-args>` tag.)

### 3. Auto-mode honor (belt-and-suspenders)

In `SKILL.md` auto mode, before extracting facts (Step 1/early Step 3), re-check
the **raw** transcript (`$DREAM_TRANSCRIPT`, *not* the preprocessed text — command
blocks may be stripped by `preprocess.sh`) with the same latest-wins logic as #1.
If the latest toggle is `--ignore`:
- Do not write anything to the vault or queue.
- Close the loop as a no-op: `COMPLETED source=skill reason=marked-private …` to
  `$DREAM_LOG`, and `report.sh --status skipped --reason "marked private"` (no
  `--title`).

This covers the rare path where `trigger.sh`'s gate is bypassed — chiefly the
compaction-continuation resolution picking a transcript that the gate didn't grep,
or a future change to the dispatch path.

### 4. Visible skip

Already covered by the `report.sh --status skipped` calls in #1 and #3. Result:
one line in the Obsidian `dream-reports/dream-<date>.md`:

```
### <HH:MM TZ> — skipped
chat: <id8> (<project>)
reason: marked private (/dream-skill --ignore)
```

Plus `SKIP private …` in `trigger.log`. No conversation content, no title.

### 5. Docs

- `README.md`: a short "Keeping a chat private" section documenting
  `/dream-skill --ignore` / `--unignore`, the one-command workflow, and the
  visible-skip behavior.
- `--help` block in SKILL.md (see #2).

### 6. Tests

Add to the existing `tests/` bash suite (mirroring `test_trigger.sh` style, using
`DREAM_DISPATCH_STUB=1` so no real headless spawn occurs):

- **Fixture** `transcript-private-ignore.jsonl` — a normal chat plus a message
  record containing `<command-name>/dream-skill</command-name> … <command-args>--ignore</command-args>`.
  → trigger.sh logs `SKIP private`, calls `report.sh --status skipped` with no
  `--title`, does **not** dispatch, writes **no** `SEEN_FILE`.
- **Fixture** `transcript-private-unignore.jsonl` — same chat with an `--ignore`
  record followed later by an `--unignore` record. → trigger.sh **dispatches**
  (latest-wins = record).
- **Regression**: an ordinary transcript (existing `transcript-3msg.jsonl`) still
  dispatches — the new gate does not affect normal chats.
- **Self-trigger guard** (the critical one): assert that `SKILL.md`'s `--help`
  block, the `description:` frontmatter, the auto-mode instructions, `README.md`,
  and `trigger.sh` itself contain **no** occurrence of the forbidden serialized
  pattern `<command-args>[^<]*--ignore` (i.e. prose mentions never look like a real
  invocation). This guarantees the feature can't accidentally mark every chat
  private.

## Self-trigger safety (invariant summary)

The single rule the implementation must hold: **detection matches the flag only
inside a `<command-args>` tag paired with the dream-skill command-name; nothing in
the codebase or skill metadata may reproduce that serialized form as literal
text.** Prose like `/dream-skill --ignore` is always safe. Test #6-guard enforces
this.

## Known trade-offs / edge cases

- **Reversibility is per-chat and chronological.** State = the last toggle in the
  transcript. Fine for the intended "I changed my mind" flow.
- **Discoverability is "best effort."** Without a forced per-session injection,
  Claude suggests the command based on the skill description. Acceptable and the
  professionally cleaner choice; the command is also self-documenting via `--help`
  and appears in the `/` menu.
- **Compaction edge.** If the user typed `/dream-skill --ignore` only in a segment
  that the continuation-resolution does not map back to, the gate could miss; the
  auto-mode honor (#3) is the backstop, and in practice the command record lives in
  the root transcript that resolution targets.

## Out of scope (possible future work)

- Per-project/folder denylist in `config.toml`.
- `--ignore` scoping to "from this point on" rather than whole-chat.
- Model-driven personal-content detection.
