# dream-skill v0.3 — Ambition Plan: Capture Decision-Guiding Depth

> Status: DESIGN / ambition. Not yet brainstormed-to-spec or scheduled. This is the north-star doc; turn into an executable plan via brainstorming -> writing-plans before building.
> Created: 2026-05-29. Supersedes the abandoned map-reduce v0.3 (commit 9e5c243 reset that to v0.2).

## The problem this fixes

v0.2 is a **fact-router**: short input -> Haiku -> one atomic bullet. It reliably captures *what happened* (a timeline) and reliably drops *what it means for the user's decisions*.

Demonstrated on a real deep-research session (2026-05-29):

| | Value |
|---|---|
| Total conversation content | ~10.6 MB (307 KB main transcript + 10.3 MB subagent research) |
| What the extractor received | ~27 KB (main transcript text only) |
| Decision content present in that input | yes (the decision being weighed, the factors for and against, the open question) |
| What got written to the vault | ~600 chars, one bullet, timeline only |

Three independent losses stacked:

1. **Input is noisy and partial.** `preprocess.sh` does not strip workflow noise (`<task-notification>` turns inflate the input) and never reads the final agent output or subagent research (where the deep analysis lives).
2. **Extraction atomizes.** `SKILL.md` auto-mode is built to emit one-line additive *facts* via `vault-writer` (`- bullet`). Even decision content that reached it was distilled to a timeline.
3. **Model is shallow.** Haiku 4.5 is a good router, weak at "synthesize what this implies."

Note on a common misconception: there is **no head/tail (1k+1k) truncation** in v2. That was a feature of the original map-reduce `preprocess.py` that was reset away. v2 keeps full messages. The right fix is NOT to add head/tail truncation (it would cut exactly the decision analysis); it is richer capture plus smart handling of genuinely-huge transcripts.

## Goal

When a conversation contains substantial persona signal or a decision the user is working through, dream-skill should capture a **structured, decision-guiding note** (context, the decision, factors, current state, open question, and any research conclusions) rather than a one-line fact, and it should do this safely (no context blowups, no quota cascades, bounded cost).

## Non-goals

- Storing raw research internals (the 10.3 MB of subagents). The user's own framing is correct: the **final agent output** is enough.
- Replacing the v0.2 fast path for trivial chats. Small/no-decision chats should still get a cheap one-bullet (or be dropped). v0.3 adds a richer path, it does not make every run expensive.
- Re-introducing the abandoned map-reduce complexity wholesale. Borrow only the large-transcript handling, scoped.

## The four changes

### 1. Preprocess: strip noise, surface the final agent output
- Strip `<task-notification>` blocks (and any tool-injection turns that carry the `user` role) in `preprocess.sh`, same way it already strips `<system-reminder>` / `<local-command>`.
- Detect when a chat ran a workflow/subagents and ensure the **final synthesis** (the last substantial assistant turn) is preserved intact, not atomized. Optionally read the workflow's referenced `<output-file>` if it still exists, instead of the subagent internals.
- Net effect: the extractor sees clean user prose + the agent's final conclusions, not 33x noise.

### 2. Capture the final agent output explicitly
- Treat the last substantive assistant message as a first-class capture target (the research payoff / the synthesis), distinct from the user's atomic facts.
- For research/decision chats, this is where the decision-guiding content actually is.

### 3. Decision-aware, structured, schema-conformant extraction (`SKILL.md`)
- New classification: when the user is **working through a decision** or shares a **substantial personal situation**, write a structured note instead of a single bullet:
  - Context / The decision being weighed / Factors (for and against) / Other party or situation / Current state / Open question / Research takeaways.
- Conform to the target vault's page schema (e.g. `me/CLAUDE.md` requires frontmatter: `tags`, `created`, `updated`, `sources`). Auto-writes currently skip this.
- Fix the `vault-writer.sh` title bug (a stray leading "u", e.g. `# uTopic` instead of `# Topic`, because macOS/BSD `sed` does not support the `\u&` title-casing escape).
- Keep the atomic-fact path for genuinely atomic facts (a date, a tool choice).

### 4. Tiered model
- Use a cheap model (Haiku) to **triage** ("is there persona/decision signal here, and how rich?") and a stronger model (Sonnet 4.6, configurable to Opus) only to **write the rich structured notes**.
- Keeps cost bounded: most runs stay Haiku-cheap; only signal-rich chats pay for Sonnet.
- Already pluggable via `DREAM_MODEL`; v0.3 makes it a two-stage decision rather than one fixed model.

### 5. (Carry-over) Safe handling of genuinely huge transcripts
- For transcripts above a token threshold, **summarize-then-extract** (a scoped version of the old map-reduce), NOT head/tail truncation.
- For most chats (like the 27 KB example) this path is never triggered.

## How it fits the existing pipeline

```
SessionEnd -> trigger.sh (unchanged: recursion guard + --no-session-persistence + threshold + lock)
           -> claude -p /dream-skill --auto <transcript>
                Step 1 preprocess.sh   [CHANGE 1: strip noise + surface final output]
                Step 1b size check      [CHANGE 5: if huge, summarize-then-extract]
                Step 2 load vault context (unchanged)
                Step 3 triage signal    [CHANGE 4a: Haiku triage]
                Step 3b extract         [CHANGE 3: decision-aware structured note]
                                        [CHANGE 4b: Sonnet writes rich notes]
                Step 4 vault-writer.sh  [CHANGE 3: schema frontmatter + title fix;
                                         support multi-section structured writes]
                Step 5/6 log + close loop (unchanged)
```

The trigger layer (and all the v0.2 safety work: recursion guard, `--no-session-persistence`, `--strict-mcp-config`, dedupe lock, threshold) stays exactly as-is. v0.3 is entirely downstream of dispatch.

## Safety and cost

- **No new cascade surface:** all changes are inside the headless skill, downstream of the guarded dispatch. The recursion guard and no-session-persistence remain the gate.
- **Cost bounded by tiering:** Haiku triage on every run; Sonnet only on signal-rich runs. Structured notes are bigger than one bullet but only written when warranted.
- **Vault safety preserved:** still add-only via `vault-writer.sh`, still undo-logged, still idempotent.

## Suggested phasing

- **P0 (cheap, high value):** Change 1 (strip noise + final-output capture) + Change 3's schema/frontmatter + title-bug fix. Pure quality win, low risk.
- **P1:** Change 3 (decision-aware structured notes) + Change 4 (tiered model). The core of the ambition.
- **P2:** Change 5 (huge-transcript summarize-then-extract). Only needed once the common cases are solid.

## Open design questions (decide before building)

1. **Structured-note threshold:** what triggers the rich path vs the one-bullet path? (e.g. "user is weighing a decision" / transcript over N tokens / a workflow ran / persona-page topics like relationships, health, career.)
2. **Where do decision notes live?** A dedicated page per decision under the right vault, or appended sections on a topic page?
3. **Re-run / update semantics:** when the same decision is revisited in a later chat, append an update vs rewrite the note? (Today vault-writer is add-only and idempotent on exact lines.)
4. **Final-output detection:** heuristic (last long assistant turn) vs explicit (read the workflow `<output-file>`)? The output-file is in `/tmp` and may be gone by run time.
5. **Triage cost:** is a Haiku triage call on every dispatch acceptable, or gate the rich path on cheaper signals first (transcript size, presence of a workflow, decision keywords)?

## Next step

If this direction is right: run `superpowers:brainstorming` to lock the open questions into a spec, then `superpowers:writing-plans` for an executable task breakdown, then build P0 first.
