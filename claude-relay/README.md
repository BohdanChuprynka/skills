# Claude Relay

Claude Code-only model-routing discipline for a user-started Opus coordinator.
The coordinator keeps the task state, delegates bounded phases to Claude Code
subagents, checks their evidence, and reports the route that actually ran.

It does not invoke or orchestrate Codex. Codex routing belongs to the separate
[`gpt-5-6-relay`](../gpt-5-6-relay) skill.

## What it routes

| Role | Best use |
| --- | --- |
| Opus | Architecture, ambiguous planning, hard diagnosis, risky review. |
| Sonnet | Implementation, tests, refactors, and bounded debugging. |
| Haiku | Reconnaissance, deterministic checks, release mechanics, monitoring. |

The skill uses Claude Code subagents for the phases. If the host exposes
child-model controls, it selects the matching model. Otherwise it still
delegates, labels the intended role, and reports the child as `host-default`
rather than pretending a specific model ran.

## Install

Clone this repository, then symlink the inner skill directory into Claude Code:

```bash
mkdir -p "$HOME/.claude/skills"
ln -s "$(pwd)/claude-relay/skills/claude-relay" \
  "$HOME/.claude/skills/claude-relay"
```

Restart Claude Code after installing or updating the skill.

## Use

Start an Opus session, then ask:

```text
/claude-relay implement <task>
```

The coordinator first creates a short route with an artifact and verification
gate for each phase. Persistent thread or project APIs are useful but not
required; Claude Code subagent controls are enough.

## Safety

- Only one child writes at a time unless write scopes are explicitly disjoint.
- A deployment phase requires explicit user authorization and the repository's
  deployment instructions.
- Every final report distinguishes the planned role from the actual model or
  host-default subagent that ran.
