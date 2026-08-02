# Parallel Workstreams Design

## Goal

Create a personal Codex skill that lets one user-started coordinator task organize independent work through separate, user-visible Codex tasks. The workflow must improve throughput without replacing Bohdan's control over which phases run in parallel, when worker tasks launch, or what external actions are authorized.

## Scope

The skill is universal across trusted local Git projects. It supports parallel planning, implementation, and review in any combination explicitly requested by the user.

The skill does not replace the existing `gpt-5-6-relay` subagent workflow. It specifically coordinates peer Codex tasks that appear in the sidebar and can be opened, inspected, and messaged directly.

## Invocation Modes

The coordinator derives the topology from the user's request instead of imposing one pipeline.

### Parallel planning followed by parallel implementation

1. Launch Sol planning tasks.
2. Consolidate and reconcile their plans in the coordinator.
3. Launch fresh Luna implementation tasks for the approved workstreams.
4. Integrate, verify, and review centrally.

### Central planning followed by parallel implementation

1. Design and iterate on plans in the coordinator task.
2. Launch Luna implementation tasks only after the plans are ready and implementation is authorized.
3. Integrate, verify, and review centrally.

### Parallel planning only

Launch planning tasks, consolidate their results, and stop for the user's review. Do not infer implementation authority.

### Parallel implementation only

Validate and group existing approved plans, then launch implementation tasks directly.

### Coupled work

Use fewer workers or keep the work in the coordinator when file overlap, ordering, shared resources, or integration risk makes parallel execution counterproductive. Do not force one task per plan.

## Human Confirmation Gate

Before creating any peer task, send one concise confirmation that states:

- which phases are central, parallel, or unauthorized;
- how many tasks each declared wave will create;
- the worker models and reasoning levels;
- who owns integration and full verification; and
- the external-action boundary.

Example:

```text
Parallel workflow ready:
- Planning: 4 Sol-high tasks
- Implementation: 3 Luna-high tasks after consolidation
- Review: main coordinator
- Finalization: integrate commits and run full verification
- External actions: no push, PR, deployment, or production changes

Proceed?
```

Create no tasks until the user approves. Approval covers only the displayed topology. Ask again before adding an undeclared worker wave or making a material topology change. Do not add redundant approvals between already-declared waves unless the user requested an intermediate gate.

## Worker Selection and Models

Keep the invoking task's existing model and reasoning configuration; the user will start the coordinator with Sol configured as desired.

- Planning workers: GPT-5.6 Sol at high reasoning, raised to xhigh for ambiguity or architectural risk.
- Implementation workers: GPT-5.6 Luna at high reasoning, raised to xhigh for security, migrations, concurrency, or subtle cross-system behavior.
- Terra is not part of the default route.

Choose worker count from actual independent workstreams, dependency order, file ownership, host capacity, and shared-resource contention. Do not hardcode a six-worker ceiling. The current task monitor can watch eight tasks per batch; use additional waves only when the approved topology and available capacity justify them.

## Permissions

Update the global Codex configuration to:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

This corrects the observed behavior where peer tasks showed a full-access label but actually started with the global `workspace-write`, `on-request`, network-restricted policy. The user explicitly approved unrestricted global access for future Codex tasks.

Full technical access does not expand task authority. Workers still must not push, open pull requests, deploy, use credentials for external actions, perform destructive operations, mutate production, or publish externally unless the user explicitly authorizes that action.

## Task Creation and Visibility

For a local Git project, create each implementation task in an isolated Codex worktree from the frozen approved base. Record the branch, base SHA, and pre-existing dirty state before dispatch. Select an explicit existing branch as the worktree starting state; use a working-tree snapshot only when the user explicitly wants uncommitted state included. Require every worker to confirm its initial HEAD and stop on a base mismatch.

Task creation is asynchronous. If creation returns only a temporary client task ID, never pass it to controls that require a real task ID. Wait until the app exposes one unambiguous ready task for the approved project and scope, then title and pin it. Stop and report the setup failure if readiness cannot be resolved safely.

Immediately after creation:

1. Give the task a descriptive phase-and-scope title.
2. Pin the task so it stays visible in the sidebar.
3. Record its task ID, host ID, phase, scope, model, worktree, dependencies, and status in the coordinator's task registry.

Keep tasks pinned after completion. Never unpin or archive them automatically; Bohdan owns cleanup.

Reuse the same task for corrections and follow-ups within one phase. Use fresh implementation tasks after a parallel planning phase by default because ownership and grouping may change and implementation should receive only the reconciled plan.

## Worker Contracts

Every worker brief must state:

- one concrete outcome;
- exact inputs and approved plan;
- owned files or responsibility;
- dependencies and frozen base;
- allowed and forbidden actions;
- focused verification requirements; and
- the required return format.

Planning workers return an evidence-backed plan and do not implement. They create or commit plan files only when the approved topology requests saved plan artifacts.

Implementation workers:

1. Implement only their assigned scope.
2. Write and run focused tests covering changed behavior.
3. Run narrowly relevant static checks when practical.
4. Commit only their assigned verified changes.
5. Return the base SHA, commit SHA, changed files, checks with actual results, unresolved risks, and external evidence not obtained.

Workers must account for other concurrent work and must not revert or absorb unrelated user changes.

## Coordinator Integration and Verification

The coordinator owns all cross-workstream decisions and final evidence.

1. Inspect every worker's task and diff; do not trust summaries alone.
2. Reject out-of-scope changes and return them to the same worker for correction.
3. Integrate accepted commits in dependency order.
4. Resolve mechanical conflicts when intent remains unchanged.
5. Stop for user direction when a conflict changes product behavior or architecture.
6. Run the full repository-required unit, integration, typecheck, lint, build, browser, and platform checks after integration, proportionate to the project.
7. Perform the declared final correctness review and security review where trust boundaries are affected.
8. Separate local proof from hosted, provider, OAuth, signing, deployment, and production gates.

Focused worker tests do not substitute for the coordinator's integrated verification.

## Steering and Failure Handling

The coordinator remains the main control surface. Bohdan may inspect or message any pinned worker directly; the coordinator must reread each task before integration so direct corrections are included.

A message sent to a running peer task may queue instead of interrupting immediately. Disclose that limitation, stop launching later phases, and use explicit phase boundaries in worker prompts to prevent unauthorized continuation.

- Retry task creation or a transient worker failure once.
- Use the same worker for incomplete or incorrect handoffs.
- Preserve completed independent work when another workstream blocks.
- Do not silently reduce, expand, or regroup an approved topology after a persistent setup failure; report it and request direction.
- Do not claim completion while a required workstream, integrated check, or declared review remains unresolved.

## Packaging

Create the source-controlled skill at:

`/Users/bohdan/Documents/IT-Work/Projects/IT/skills/parallel-workstreams`

Install it globally through:

`/Users/bohdan/.codex/skills/parallel-workstreams`

The installed path will be a symlink to the source-controlled directory. The package will contain the required `SKILL.md`, matching `agents/openai.yaml`, and only those supporting references or evaluation fixtures that materially improve reliability.

## Validation

Develop the skill test-first with baseline and post-skill scenarios covering at least:

1. A request for parallel planning only, verifying that implementation does not launch.
2. Central planning followed by one implementation wave.
3. Explicit parallel planning followed by parallel implementation.
4. Overlapping plans that must be grouped or serialized.
5. A topology change that requires renewed user confirmation.
6. Worker setup failure without silent topology drift.
7. Model routing between Sol planning and Luna implementation.
8. Pinned task creation and retention.
9. Focused worker tests followed by integrated coordinator verification.
10. Full access without inferred push, deployment, destructive, or production authority.

Run the skill validator, verify UI metadata, inspect the global configuration change, confirm the installation symlink, and forward-test realistic prompts with fresh agents before calling the skill ready.

## Success Criteria

The skill is ready when a fresh coordinator can accurately restate a requested topology, wait for approval, create and pin the correct peer tasks, preserve phase and authority boundaries, route Sol and Luna as approved, integrate worker commits safely, run final verification centrally, and stop honestly at unresolved local or external gates.
