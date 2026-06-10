# session-continue

Import a Claude Code, Codex, or other `continues`-supported coding session into the current agent thread by source and session id.

This is the small wrapper for the workflow:

```text
Use $session-continue from claude <session-id> -- continue the task
/session-continue from codex <session-id> -- continue the task
```

It does not launch a second Claude or Codex process. It resolves the source session, generates a sanitized handoff with `continues`, and tells the current agent to keep working from that context.

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/session-continue
./setup.sh
```

The setup script:

- symlinks the skill into `~/.claude/skills/session-continue`
- copies `/session-continue` into `~/.claude/commands/session-continue.md`
- copies the full skill into `~/.codex/skills/session-continue`

Restart Codex after setup. Codex scans skills at startup.

## Usage

Claude Code:

```text
/session-continue from codex <session-id> -- finish the task
```

Codex:

```text
Use $session-continue from claude <session-id> -- finish the task
```

The source can be any tool supported by `continues`: `claude`, `codex`, `copilot`, `gemini`, `opencode`, `droid`, `cursor`, `amp`, `kiro`, `crush`, `cline`, `roo-code`, `kilo-code`, `antigravity`, `kimi`, or `qwen-code`.

## Options

```text
--from <source>       Source tool, such as claude or codex
--id <session-id>     Exact session id or unique prefix
--preset <name>       minimal, standard, verbose, or full
--no-redact           Keep raw handoff text
--require-cwd         Fail if source cwd differs from current cwd
--json                Emit JSON containing the handoff string
```

Natural wording also works:

```text
from codex session id: abc123 -- keep going
```

## Safety

The helper:

- resolves exact ids before prefix matches
- rejects ambiguous prefixes with candidate ids
- rebuilds the `continues` index once on a miss
- redacts likely API keys, bearer tokens, GitHub tokens, Slack tokens, AWS keys, and env-style secret assignments
- warns when the imported session cwd differs from the current cwd

The imported transcript is treated as untrusted context. Current user instructions, system/developer instructions, and the live repo state always win.

## Prerequisites

- Node.js
- One of:
  - globally installed `continues` or `cont`
  - `npm`, so the helper can run pinned `npm exec --package continues@4.1.1`

## Develop

```bash
node --test tests/session-continue.test.mjs
./setup.sh
./sync.sh
```

Run `./sync.sh` after editing the skill to refresh the Codex install, then restart Codex.
