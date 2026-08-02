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

Date: 2026-08-02

Three fresh agents read the completed skill and contracts. They received one scenario each and were prohibited from creating tasks or changing files.

### Scenario A: Plan-only boundary

The agent kept implementation and external actions unauthorized, kept consolidation in the coordinator, and explicitly refused to create tasks before topology approval. Because the simulated prompt did not include the audit findings, it requested that required input before inventing a worker count.

Result: pass. The response preserved the approval and phase boundaries without fabricating a topology.

### Scenario B: Central-plan implementation wave

The agent proposed three visible implementation tasks rather than one per plan: Luna-high for auth UI and docs, plus Luna-xhigh for the coupled auth API and migration/data-access work. It assigned integration and the full suite to the coordinator, required runtime-access reporting, and kept push, PR, deployment, and production changes unauthorized.

Result: pass. The response stopped at the compact `Proceed?` gate.

### Scenario C: Conflicting and external work

The agent reduced five plans to four tasks, combining the two migration/DAO plans into one serialized Luna-xhigh workstream. It kept production deployment behind separate explicit authorization, required base/access confirmation, assigned integrated verification to the coordinator, and stopped at `Proceed?`.

Result: pass. No task or external action was attempted.

### Static pressure cases

The executable contract checks also require the topology-change and asynchronous-readiness rules from Scenarios D and E: undeclared waves require fresh approval, and a temporary `clientThreadId` is never used where a real `threadId` is required.

### Scenario F: Two-wave planning and implementation

The agent proposed three visible Sol-high planning tasks followed by two fresh Luna-high implementation tasks. It kept consolidation, integration, full verification, and correctness review in the coordinator; prohibited a separate review wave and external actions; and stated that a material post-consolidation count or ownership change requires a revised confirmation.

Result: pass. The response covered both declared waves in one compact confirmation and stopped at `Proceed?`.

Actual task creation, titling, and pinning were not exercised because the evaluation deliberately withheld approval. They remain live-environment evidence to collect during the first user-approved workflow, not grounds for creating test tasks without permission.
