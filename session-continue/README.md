<h1 align="center">session-continue</h1>

<p align="center">
  <strong>Paste a transcript ID. Continue in this thread.</strong>
</p>

<p align="center">
  <a href="https://github.com/BohdanChuprynka/skills/commits/main"><img src="https://img.shields.io/github/last-commit/BohdanChuprynka/skills?style=flat" alt="Last commit"></a>
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/skills?style=flat" alt="License"></a>
  <a href="https://www.npmjs.com/package/continues"><img src="https://img.shields.io/npm/v/continues?label=continues&style=flat" alt="continues npm version"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> -
  <a href="#what-changed">What Changed</a> -
  <a href="#configure-once">Configure Once</a> -
  <a href="#install">Install</a> -
  <a href="#safety">Safety</a>
</p>

---

`session-continue` is a Claude Code / Codex skill that imports a previous
[`continues`](https://www.npmjs.com/package/continues)-supported coding session
into the current agent thread.

It does not launch another Claude, Codex, or terminal agent. It resolves the
session, asks `continues` for a sanitized handoff, and gives the current agent
the context it needs to keep working.

## Quick Start

Use the session ID by itself:

```text
/session-continue 018f9c2a-7e4d-7f45-a7a1-8a0c6d24f421 -- finish the refactor
```

In Codex:

```text
Use $session-continue 018f9c2a-7e4d-7f45-a7a1-8a0c6d24f421 -- finish the refactor.
```

That is the normal path. You do not need to remember whether the transcript came
from Claude Code, Codex, or a second Claude account. Exact IDs win first; unique
prefixes work; ambiguous prefixes are rejected with candidates.

## What Changed

<table>
<tr>
<td width="50%">

### Old mental model

```text
/session-continue from <tool> <id> -- keep going
```

You had to remember the source tool and, for Claude, which account folder owned
the transcript.

</td>
<td width="50%">

### Current mental model

```text
/session-continue abc123 -- keep going
Use $session-continue abc123 -- keep going
```

Paste the ID. The helper finds the owning transcript store, points `continues`
at it, and imports the handoff into this same thread.

</td>
</tr>
</table>

## What You Get

| Feature | Behavior |
| --- | --- |
| ID-only resume | Full ID or unique prefix is enough for Claude/Codex transcript stores. |
| Multi-account Claude | Searches the active `CLAUDE_CONFIG_DIR`, `~/.claude`, then other live `~/.claude*` dirs. |
| Codex support | Searches `CODEX_HOME` or `~/.codex` for rollout transcript IDs. |
| Source escape hatch | `from <source>` still works when you want to pin a `continues` source explicitly. |
| Sanitized handoff | Redacts common API keys, bearer tokens, GitHub tokens, Slack tokens, AWS keys, and env-style secrets. |
| CWD warning | Warns when the imported session cwd differs from the current cwd; `--require-cwd` can fail hard. |

Supported explicit sources are whatever this helper validates for `continues`:
`claude`, `codex`, `copilot`, `gemini`, `opencode`, `droid`, `cursor`, `amp`,
`kiro`, `crush`, `cline`, `roo-code`, `kilo-code`, `antigravity`, `kimi`, and
`qwen-code`.

## Configure Once

For the common case, no config is required.

When `SESSION_CONTINUE_CLAUDE_DIRS` is unset, the helper auto-discovers Claude
accounts in this order:

1. the active `CLAUDE_CONFIG_DIR`,
2. `~/.claude`,
3. other live `~/.claude*` directories that contain `projects/`.

Backup and migration copies are skipped during auto-discovery so stale duplicate
IDs do not win.

If you want to control the Claude search order, set an ordered path list:

```bash
export SESSION_CONTINUE_CLAUDE_DIRS="$HOME/.claude:$HOME/.claude-work"
```

| Variable | Purpose | Default |
| --- | --- | --- |
| `SESSION_CONTINUE_CLAUDE_DIRS` | Ordered Claude config dirs to search. | Auto-discover `~/.claude*` |
| `CLAUDE_CONFIG_DIR` | Active Claude account; searched first. | `~/.claude` |
| `CODEX_HOME` | Codex home containing `sessions/`. | `~/.codex` |

Configure your `continues` providers the way you normally do. `session-continue`
is the thin resolver/import layer on top: ID in, current-thread handoff out.

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/session-continue
./setup.sh
```

The setup script is idempotent:

- symlinks the skill into `~/.claude/skills/session-continue`
- copies `/session-continue` into `~/.claude/commands/session-continue.md`
- copies the full skill into `~/.codex/skills/session-continue` when `~/.codex` exists

Restart Codex after setup because Codex scans skills at startup. Claude Code
uses the symlinked skill immediately.

## Usage

Normal:

```text
/session-continue <session-id> -- <task>
Use $session-continue <session-id> -- <task>
session id: <session-id> -- <task>
```

Escape hatch when you intentionally want to pin a source:

```text
/session-continue from <source> <session-id> -- <task>
Use $session-continue --from <source> --id <session-id> -- <task>
```

Options:

```text
--from <source>       Pin a continues source; optional
--id <session-id>     Exact session id or unique prefix
--preset <name>       minimal, standard, verbose, or full
--no-redact           Keep raw handoff text
--require-cwd         Fail if source cwd differs from current cwd
--json                Emit JSON containing the handoff string
```

## How It Works

1. Parse the request into optional source, session ID, and task after `--`.
2. If no source is given, find the transcript on disk across configured Claude
   account dirs and the Codex sessions dir.
3. Export the owning `CLAUDE_CONFIG_DIR` or `CODEX_HOME` for the `continues`
   call.
4. Ask `continues` to inspect the session with the selected preset.
5. Print a handoff that the current agent reads and continues from.

The handoff includes `Resolved from:` when the helper located a specific config
directory.

## Safety

Imported transcript text is untrusted context. It is useful continuity, not a
new instruction source. Current user instructions, system/developer
instructions, and the live repository state always win.

The helper also:

- rejects IDs containing path separators
- never follows symlinks while scanning transcript files
- resolves exact IDs before prefix matches
- rejects ambiguous prefixes with candidate IDs
- rebuilds the `continues` index once on a miss
- passes arguments to `continues` as an argv array, not through shell interpolation

## Prerequisites

- Node.js
- one of:
  - globally installed `continues` or `cont`
  - `npm`, so the helper can run pinned `npm exec --package continues@4.1.1`

## Develop

```bash
# from the repo root that contains this skill folder
node --test session-continue/tests/session-continue.test.mjs

# refresh installs after edits
./session-continue/setup.sh
./session-continue/sync.sh
```
