---
name: gpt-5-6-relay
description: Route a task through a user-started GPT-5.6 Sol coordinator and Codex subagents, using model-aware roles when the host exposes them and transparent fallbacks when it does not. Use when the user asks for GPT-5.6 relay, Sol/Terra/Luna routing, model-aware Codex delegation, or coordinated implementation through subagents.
---

# GPT-5.6 Relay

Route work inside Codex. A user-started GPT-5.6 Sol session is the coordinator:
it plans, delegates bounded implementation and verification phases to Codex
subagents, checks every handoff, and owns the final result. Do not invoke,
recommend, or orchestrate Claude threads; Claude routing belongs to a separate
Claude-only skill.

The tiers below express the right level of reasoning for a phase. Use exact
GPT-5.6 model IDs and thinking levels only if the host actually exposes those
controls. Otherwise, delegate through the available Codex subagent controls
and report the role recommendation rather than falsely claiming a child ran as
Terra or Luna.

## Preflight

1. Restate the outcome, acceptance criteria, constraints, allowed mutations,
   and deployment authority. Do not infer destructive or external authority.
2. Confirm that Codex subagent controls are available. Persistent project or
   thread APIs are useful but are NOT required for this relay.
3. Record the starting state. In a Git repository, capture the branch,
   revision, and dirty files so relay changes are distinguishable from
   pre-existing work.
4. Classify the work by uncertainty:
   - **Clear:** solution and finish line are known.
   - **Judgment-heavy:** implementation is bounded, but tradeoffs or failure
     modes need thought.
   - **Open-ended:** problem, architecture, or safe path must be discovered.

Preflight is complete when the finish line is checkable and every external side
effect is authorized. Do not stop merely because Codex lacks persistent-thread
or project-listing APIs.

## Roster

| Role | Reach for it when | Recommended effort |
| --- | --- | --- |
| **Sol** | Ambiguous planning, architecture, hard diagnosis, high-risk review, resolving child disagreement. | Extra High; Ultra only for intentional nested delegation. |
| **Terra** | Everyday implementation, tests, refactors, code review, bounded debugging, settled plans. | High; Extra High for subtle invariants or a non-obvious failed attempt. |
| **Luna** | Reconnaissance, deterministic edits, formatting, focused checks, release mechanics, monitoring. | Light; raise to Medium/High for branching operational work. |

The coordinator is Sol when the user has started a GPT-5.6 Sol session. Do not
create a second coordinator. If the active session is not Sol and the host
cannot create a Sol child, make the limitation explicit and use the current
session only for work it can safely own.

Never use every role by default. A phase earns a child only when it produces a
needed artifact, reduces uncertainty, or independently verifies work. Do not
leave a Luna role to decide an ambiguous production question. Do not use Sol
for mechanical execution merely because it is stronger.

## Build the route

Before delegating, create the shortest useful route:

| Phase | Recommended role | Actual owner | Deliverable | Gate |
| --- | --- | --- | --- | --- |
| ... | Sol / Terra / Luna | coordinator / Codex subagent | concrete artifact | checkable evidence |

Start from these routes, then adapt:

- **Mechanical task:** Luna performs the edit and focused check.
- **Normal feature or fix:** Terra implements and tests; Luna performs
  mechanical closeout or release only when authorized.
- **Ambiguous or cross-system work:** Sol settles the plan and risks; Terra
  implements; Sol reviews the risky decision; Luna releases only when
  authorized.
- **Production incident:** Luna gathers current evidence; Sol diagnoses;
  Terra fixes and adds a regression test; Luna releases and monitors only when
  authorized.

Read `DEPLOYMENT.md` completely before assigning a deployment phase. Permit
only one writing child at a time unless scopes are explicitly disjoint. A
parallel route needs an integration gate.

## Delegate through Codex subagents

Use Codex's subagent controls as the normal execution mechanism. When the host
permits child model and effort selection, use the matching role and record the
actual model/effort. When it does not, create the bounded Codex subagent anyway
and mark its model/effort as `host-default`; do not call it Terra or Luna in
the final report.

Give every child a self-contained brief:

```markdown
Relay role: <Sol/Terra/Luna responsibility>
Outcome: <one concrete result>
Inputs: <paths, commits, URLs, evidence, and prior artifacts>
Constraints: <scope, invariants, authority, and forbidden actions>
Acceptance: <checks that prove completion>
Return: <artifact or concise handoff, including unresolved risks>
```

Use follow-up messages on the same child to correct an incomplete handoff.
Create a new child when responsibility changes. A child may read, investigate,
edit, test, or review only within its stated scope. Do not pass a summary
forward as if it were the artifact; pass the plan, diff, test output, commit,
or production evidence itself.

## Verify, escalate, integrate

After each handoff, the Sol coordinator must:

1. Check the deliverable against its gate.
2. Update the route with the child identifier, actual available model/effort,
   artifact, and status.
3. Retry at the same role only when the failure was transient or the brief was
   incomplete.
4. Escalate Luna work to Terra, or Terra work to Sol, when evidence reveals a
   capability gap or new uncertainty.
5. Re-plan with Sol when new evidence invalidates the route rather than piling
   patches onto a broken plan.

Implementation passes only when requested behavior exists, focused tests pass,
and unrelated user changes remain untouched. Review passes only when every
actionable finding is fixed and rechecked or explicitly rejected with evidence.

## Final report

Lead with the completed outcome. Then report:

- the route actually used, including the recommended role and actual Codex
  subagent or model for each phase;
- child identifiers and artifacts produced;
- checks passed;
- substitutions, escalations, or skipped phases and why; and
- deployment revision and health evidence when deployment was authorized.

Never report the planned route as the route actually run, and never describe a
host-default subagent as a specific GPT-5.6 child model.
