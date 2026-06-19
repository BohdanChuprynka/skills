# session-continue

Continue a Claude Code, Codex, or other [`continues`](https://www.npmjs.com/package/continues)-supported coding session **inside your current agent thread** — by session id alone.

It does not launch a second Claude or Codex process. It resolves the source session, generates a sanitized handoff with `continues`, and tells the current agent to keep working from that context.

```text
/session-continue abc123 -- continue the task                # source auto-detected
/session-continue from codex abc123 -- continue the task     # source pinned
```

## Why

Two things make handing a session off painful:

1. **You have to name the tool.** Was that id from Claude or Codex?
2. **Multiple accounts live in different folders.** If you run more than one Claude
   account, each keeps its transcripts in its own `CLAUDE_CONFIG_DIR` (e.g.
   `~/.claude` and `~/.claude-personal`). When you hit a limit on one account and
   switch to the other, `continues` only sees the *active* account's folder — so a
   session from the account you just left won't resolve, and you end up explaining
   "no, it's in my *other* folder."

session-continue removes both. **The source is optional**, and an id is located
across every configured Claude account directory **and** the Codex sessions
directory. Session ids are unique per-file, so a full id resolves deterministically
no matter which account or tool created it. Paste the id, keep working.

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/session-continue
./setup.sh
```

The setup script (idempotent — safe to re-run after pulling updates):

- symlinks the skill into `~/.claude/skills/session-continue`
- copies `/session-continue` into `~/.claude/commands/session-continue.md`
- copies the full skill into `~/.codex/skills/session-continue` (if `~/.codex` exists)

Restart Codex after setup — Codex scans skills at startup. (Claude Code picks the symlinked skill up immediately.)

## Usage

Claude Code:

```text
/session-continue <session-id> -- finish the task            # auto-detect source + account
/session-continue from codex <session-id> -- finish the task # pin the source
```

Codex:

```text
Use $session-continue from claude <session-id> -- finish the task
```

The source, when given, can be any tool supported by `continues`: `claude`, `codex`, `copilot`, `gemini`, `opencode`, `droid`, `cursor`, `amp`, `kiro`, `crush`, `cline`, `roo-code`, `kilo-code`, `antigravity`, `kimi`, or `qwen-code`. Auto-detection covers Claude and Codex (the file-based tools); pass others explicitly.

Natural wording also works:

```text
from codex session id: abc123 -- keep going
```

## Multiple Claude accounts

No setup is required for the common case. With `SESSION_CONTINUE_CLAUDE_DIRS`
unset, the helper auto-discovers your accounts:

1. the active `CLAUDE_CONFIG_DIR` (searched first),
2. `~/.claude`,
3. any other `~/.claude*` directory that actually contains transcripts,

…while skipping backup/migration copies so a stale duplicate id can never win.

If your accounts live somewhere non-standard, or you want to control the search
order explicitly, set an ordered, `:`-separated list (this wins over
auto-discovery — you own the order):

```bash
# in your shell profile
export SESSION_CONTINUE_CLAUDE_DIRS="$HOME/.claude:$HOME/.claude-work"
```

The directory that owns the id is shown in the handoff as `Resolved from:` and is
exported to `continues` as `CLAUDE_CONFIG_DIR`. **The first matching directory in
scan order wins** if the same id exists in more than one.

| Variable | Purpose | Default |
| --- | --- | --- |
| `SESSION_CONTINUE_CLAUDE_DIRS` | Ordered `:`-separated Claude config dirs to search | auto-discover `~/.claude*` |
| `CLAUDE_CONFIG_DIR` | The active Claude account; searched first | `~/.claude` |
| `CODEX_HOME` | Codex home | `~/.codex` |

## How it works

1. Parse the request into an optional source, a session id (or unique prefix), and an optional task after `--`.
2. If the source is omitted (or is `claude`), locate the id on disk: Claude transcripts are `…/projects/<project>/<id>.jsonl`; Codex transcripts are `…/sessions/<date>/rollout-<ts>-<id>.jsonl`. Exact ids win over prefixes and honour scan order.
3. Point `continues` at the owning directory (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`), generate a sanitized handoff, and hand it to the current agent.

## Options

```text
--from <source>       Source tool, such as claude or codex (optional; auto-detected)
--id <session-id>     Exact session id or unique prefix
--preset <name>       minimal, standard, verbose, or full
--no-redact           Keep raw handoff text
--require-cwd         Fail if source cwd differs from current cwd
--json                Emit JSON containing the handoff string
```

## Safety

The imported transcript is treated as **untrusted context** — useful continuity, not a new instruction source. Current user instructions, system/developer instructions, and the live repo state always win.

The helper also:

- resolves exact ids before prefix matches, and rejects ambiguous prefixes with candidate ids
- rebuilds the `continues` index once on a miss
- redacts likely API keys, bearer tokens, GitHub tokens, Slack tokens, AWS keys, and env-style secret assignments
- warns when the imported session cwd differs from the current cwd
- locates sessions by reading filenames only: it rejects ids containing path separators, never follows symlinks while scanning, excludes backup/migration directories from auto-discovery, and passes the id to `continues` as an argv array (no shell interpolation)

## Prerequisites

- Node.js
- One of:
  - globally installed `continues` or `cont`
  - `npm`, so the helper can run pinned `npm exec --package continues@4.1.1`

## Develop

```bash
# from the repo root that contains this skill folder:
node --test session-continue/tests/session-continue.test.mjs
./session-continue/setup.sh
./session-continue/sync.sh   # refresh the Codex install after edits, then restart Codex
```
