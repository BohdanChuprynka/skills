# session-retro

End-of-session review for Claude Code and Codex. Finds the work that should have been a tool,
the work that got redone, and the work that should not have happened.

## Why it reads the transcript instead of asking the model

A long session gets compacted. By the end, the model's account of the early work is a summary
of a summary, and the detail that makes a retrospective useful is exactly what a summary drops.
The session transcript on disk is neither compacted nor flattering, so this measures it.

On its first real run it found two things the model had not remembered: seven identical reads of
one background-task file, and nine of thirteen HTTP fetches returning 429.

## What it measures

`scan.py` parses the session JSONL and reports:

- active time, with breaks over 30 minutes excluded so one overnight gap does not swamp the total
- tool calls per tool, and how many errored
- bytes of tool output pulled into context
- **runs of the same tool back to back** — the signature of a loop that wanted a script
- **exact repeats** — same tool, same input, more than once
- waits over a minute

## Usage

```bash
python3 scan.py                 # newest session for the current project
python3 scan.py --list          # what is available
python3 scan.py --session <id>  # a specific one
python3 scan.py --selftest
```

In Claude Code, `/session-retro`. The skill reads the numbers, classifies what they show, and
appends a ranked short list to the backlog.

## The backlog

Findings append to `$SESSION_RETRO_LOG`, or `optimizations.md` in the working directory. One
retrospective is an anecdote. Ten of them show the same twenty minutes going missing every day,
which is a target you can act on.

## What it deliberately does not do

It does not assume the answer is more automation. Three of the five findings on its first run
were the opposite: fewer calls, a cache, and one thing to stop doing. When a session went wrong
because the input was bad rather than slow, the skill says so instead of proposing a script,
because automating on top of bad input produces wrong answers faster.

It also caps output at five items. A retrospective that returns five new tools to build is a
wish list.

## Install

```bash
./setup.sh
```

Symlinks `skills/session-retro` into `~/.claude/skills/`. Remove the symlink to uninstall.

## Requirements

Python 3.9+. No dependencies. Reads only local transcript files and writes only the backlog.
