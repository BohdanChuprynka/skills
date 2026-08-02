# Parallel Workstreams Behavioral Results

## RED: No-skill baseline

Date: 2026-08-02

All baseline agents received one scenario, no design context, and instructions not to call tools or change files.

### Scenario A: Plan-only boundary

Agent response:

> “I’ll split the audit findings into independent, plan-only workstreams and create one visible Codex task for each. Each task will return scope, proposed changes, risks, dependencies, and verification steps without editing files. I’ll wait for all tasks, reconcile overlaps and conflicts, then bring you one consolidated plan with links to the individual tasks for review.”
>
> Next, I would create the visible tasks with the thread-creation tool, wait for their results, and consolidate them without implementing anything.

Observed failure:

- Preserved the plan-only boundary.
- Intended to create one task per workstream rather than first presenting an approved grouping.
- Did not stop for the required compact topology confirmation.
- Did not mention titling and pinning the created tasks.

### Scenario B: Central-plan implementation wave

Agent response:

> “I’ll create one visible Codex task per approved plan, with isolated ownership/worktrees and instructions to implement and verify only that plan. I’ll monitor each task, bring the completed changes back here, review and merge them in the coordinator, resolve integration issues, then run the full test suite and report the evidence.”
>
> Next, I would create those visible tasks with `create_thread`, one per plan, rather than spawning subagents.

Observed failure:

- Correctly kept integration and the full suite in the coordinator.
- Defaulted to one task per plan instead of grouping by dependencies, file overlap, and shared resources.
- Did not state the Luna high/xhigh implementation routing.
- Did not stop for the required compact topology confirmation.
- Did not mention titling and pinning the created tasks.

### Scenario C: Conflicting and external work

Agent response:

> “I’ll parallelize the three independent plans in visible Codex tasks. The two plans touching the same migration and DAO will be combined or sequenced to avoid conflicting edits. Production deployment will remain a separate gated step; I’ll request explicit approval after verification and rollback readiness are confirmed.”

Observed failure:

- Correctly grouped or sequenced overlapping writers.
- Correctly separated production deployment behind explicit approval.
- Did not stop for approval before creating the three peer tasks.
- Did not state worker models, coordinator finalization, or pinning in a compact topology confirmation.

## GREEN: With-skill results

Not run yet.
