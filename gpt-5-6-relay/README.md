# GPT-5.6 Relay

Codex-only model-routing discipline for a user-started GPT-5.6 Sol session.
Sol keeps the task state, delegates bounded phases to Codex subagents, checks
their evidence, and reports the route that actually ran.

It is not a Claude orchestrator. A Claude-only relay belongs in Claude's own
skill environment.

## What it routes

| Role | Best use |
| --- | --- |
| Sol | Architecture, ambiguous planning, hard diagnosis, risky review. |
| Terra | Implementation, tests, refactors, and bounded debugging. |
| Luna | Reconnaissance, deterministic checks, release mechanics, monitoring. |

The skill uses Codex subagents for the phases. If the host exposes child-model
and effort controls, it selects the matching model. Otherwise it still
delegates, labels the intended role, and reports the child as `host-default`
rather than pretending a specific model ran.

## Install

Clone this repository, then symlink the inner skill directory into Codex:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
ln -s "$(pwd)/gpt-5-6-relay/skills/gpt-5-6-relay" \
  "${CODEX_HOME:-$HOME/.codex}/skills/gpt-5-6-relay"
```

Restart Codex after installing or updating the skill.

## Use

Start a GPT-5.6 Sol session, then ask:

```text
Use $gpt-5-6-relay to implement <task>.
```

The coordinator first creates a short route with an artifact and verification
gate for each phase. It does not treat persistent project-listing or thread
APIs as prerequisites; Codex subagent controls are enough.

## Safety

- Only one child writes at a time unless write scopes are explicitly disjoint.
- A deployment phase requires explicit user authorization and the repository's
  deployment instructions.
- Every final report distinguishes the planned role from the actual model or
  host-default subagent that ran.
