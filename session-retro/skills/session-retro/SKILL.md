---
name: session-retro
description: Look back at a finished working session and find what should have been done faster or differently. Measures the transcript rather than recalling it, then proposes a ranked short list and logs it. Use for "/session-retro", "retro this session", "how could we have done this faster", "what should we automate", or at the end of a GTM day.
---

# session-retro

End-of-session review. The point is to find the work that should have been a tool, the work
that was redone, and the work that should not have happened at all.

**Argue from the transcript, not from memory.** A long session gets compacted, so by the end
the model's recollection of the early work is a summary of a summary. The transcript on disk
is neither compacted nor flattering.

## 1. Measure

```bash
python3 ~/.claude/skills/session-retro/scan.py            # newest session for this project
python3 ~/.claude/skills/session-retro/scan.py --list     # pick a different one
python3 ~/.claude/skills/session-retro/scan.py --session <id>
```

It reports active time (breaks excluded), tool calls and errors, bytes pulled into context,
runs of the same tool back to back, exact repeated calls, and waits over a minute.

Read the numbers before forming an opinion. `9x browser_screenshot` and `7x Read` of one file
are facts. "It felt slow" is not.

## 2. Classify what the numbers show

Six things worth finding, roughly in order of how much they cost:

1. **A loop that wanted a script.** A long run of one tool with the same shape. Four browser
   calls to send one message means 100 calls for 25 messages. Write the tool instead.
2. **Work redone because the input was wrong.** A stale link, a ledger that disagreed with the
   source, a number taken from a blog. The fix is checking the source earlier, not going faster.
3. **Waiting.** Rate limits, long scans, blocked runs. Usually fixed by pacing, batching, or
   starting the slow thing first and doing other work while it runs.
4. **Bytes for nothing.** Big payloads pulled into context to extract one field. Filter at the
   source: `--json`, a `jq`/python filter, `head`, a narrower query.
5. **Round trips.** Questions asked one at a time that could have been asked together, or a
   confirmation sought for something already authorised.
6. **Work that should not have happened.** The most valuable category and the easiest to skip.
   Anything built before it was known to be needed.

## 3. Propose

At most five items. Rank by time saved per week, not by how interesting the fix is.

Each item: what happened, with the number attached; what it should have been; and the next
action, small enough to do in one sitting.

**Do not assume the answer is more AI.** Often it is fewer calls, an existing CLI, a cron, a
saved query, or dropping the step. Say so when that is the case. A faster wrong method is worse
than the slow right one, so when the problem was bad input, name that instead of proposing
automation on top of it.

Name the principle alongside the fix. "Batch the reads" carries further than "I rewrote the loop."

## 4. Log

Append to the backlog, newest first. The path is `$SESSION_RETRO_LOG` if set, otherwise
`optimizations.md` in the current working directory:

```markdown
## YYYY-MM-DD — <session id, first 8 chars>

- **<one line>** — <number that proves it>. Fix: <action>. Status: open
```

Mark items done when they are done. The value compounds across sessions: one retro is an
anecdote, ten show that the same twenty minutes is lost every day, and that is a real target.

## What good looks like

Fewer than five items, each with a number attached, at least one of them a thing to stop doing.
If a retro produces five new tools to build, it is a wish list, not a retrospective.
