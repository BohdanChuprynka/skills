---
name: routing-mode
description: Use when implementing a nontrivial code feature, refactor, or multi-step bugfix in a git-backed project — real coding work worth offloading to a cheaper model to save cost and quota. Also use when the user says "routing-mode", "route this", "use routing", "plan then delegate", "have Codex build it", or "delegate to Codex". Do NOT use for trivial one-line edits, throwaway snippets, non-code or knowledge-work tasks, quick questions, when the working directory is not a git repo, or when the Codex CLI is not installed.
---

# Routing Mode

## Overview

Split coding work by cost. **Planning** — understanding the codebase, designing, writing and reviewing a plan — stays on this Claude session: it is reasoning-heavy but token-light. **Execution** — actually writing the code — delegates to the Codex CLI on `gpt-5.5`, which is far cheaper per output token, and output tokens are where coding spends. Planning is the leverage; execution is the volume. Route each to the right tier.

**Never blind-execute.** The plan is reviewed by a fresh, zero-context agent before any code is written.

**REQUIRED SUB-SKILL:** use `superpowers:writing-plans` to produce the implementation plan.

## When to use

- Implementing a real feature, refactor, or multi-step bugfix in a **git repo**.
- The task is large enough that offloading the code-writing saves meaningful cost or quota.

## When NOT to use

- Trivial one-line edits, throwaway snippets, quick questions.
- Non-code / knowledge-work tasks.
- Not inside a git repo, or the Codex CLI is not installed (`command -v codex`).

## Pipeline

1. **Plan (this session).** Discuss the feature, then use `superpowers:writing-plans` to write the implementation plan to a file in the repo (e.g. `docs/plan-<feature>.md`).
2. **Zero-context review — the gate.** Dispatch a subagent with **only the plan file** (no conversation history) and ask it to find gaps, wrong assumptions, missing edge cases, and risky steps. Fold its findings back into the plan. The plan ships to Codex only after this review.
3. **Delegate execution.** Ensure the working tree is clean (commit or stash first), then run the helper — it preflights git and auth, hands the plan to Codex `gpt-5.5` at effort `high`, and prints the resulting diff:
   ```bash
   bash "<skill-dir>/scripts/route-to-codex.sh" docs/plan-<feature>.md
   ```
   `<skill-dir>` is this skill's base directory (announced when the skill loads).
4. **Verify (this session).** Review the printed diff against the plan and run the tests. If something is wrong, re-run step 3 with corrective instructions after `--`:
   ```bash
   bash "<skill-dir>/scripts/route-to-codex.sh" docs/plan-<feature>.md -- "Fix: <feedback>"
   ```
5. **Hand back.** Summarize what changed. **Do not commit** — the user commits after reviewing.

## Safety

The default sandbox is `danger-full-access`: Codex runs arbitrary shell with **no sandbox** — network, package installs, file deletes. The rail is step 3's clean-tree requirement: every change Codex makes is a reviewable, revertable diff. To tighten, set `ROUTING_SANDBOX=workspace-write` (file edits + sandboxed commands, no network) — see `docs/configuration.md`.

## Quick reference

| Knob | Default | Override |
|---|---|---|
| model | `gpt-5.5` | `ROUTING_MODEL` env / `-m` |
| effort | `high` | `ROUTING_EFFORT` env / `--effort` |
| sandbox | `danger-full-access` | `ROUTING_SANDBOX` env / `-s` |
| dirty tree | refuse | `--allow-dirty` |

Run `bash scripts/route-to-codex.sh --help` for the full flag list.

## Common mistakes

- **Skipping the zero-context review.** That gate is the whole point — the cheap model executes the plan; it does not catch design flaws. Review the plan with fresh eyes first.
- **Letting Codex commit.** It is instructed not to; confirm with `git log` and commit yourself after verifying.
- **Dirty tree before handoff.** The diff then mixes your work with Codex's. Stash first.
- **Using it for tiny tasks.** The plan → review overhead is not worth it for a one-liner — just edit directly.
