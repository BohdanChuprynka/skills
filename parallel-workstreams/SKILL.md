---
name: parallel-workstreams
description: Use when the user wants one Codex task to coordinate multiple visible tasks, parallel chats, peer worktrees, parallel planning, parallel implementation, or consolidated multi-task review in the Codex app.
---

# Parallel Workstreams

## Overview

Coordinate user-owned Codex tasks while keeping the invoking task responsible for topology, decisions, integration, and final evidence. Use peer tasks for independent plan-sized outcomes; use ordinary subagents only when another explicitly selected workflow owns them.

**REQUIRED:** Read [references/contracts.md](references/contracts.md) completely before proposing or creating tasks.

## Hard Gates

- Require explicit user intent to create visible peer tasks.
- Confirm that task creation, listing, reading, messaging, waiting, titling, and pinning controls are available. Do not use subagents as a silent fallback.
- Freeze the project, branch, base SHA, dirty state, authority, and finish line.
- Derive central and parallel phases from the user's request. Do not invent another worker wave.
- Create no peer task before approval.

## Workflow

1. Group work by dependency, file overlap, shared resources, and integration risk. Use the useful worker count, not one task per plan or a fixed ceiling.
2. Show the compact phase confirmation from the contracts reference. Stop the turn and wait for approval.
3. After approval, create only the declared tasks. Use isolated worktrees for Git implementation, verify each base, assign Sol to planning and Luna to implementation, and record a task registry.
4. Title and pin each ready task. Pin every ready task immediately. Never unpin or archive it; the user owns cleanup.
5. Reuse a task for corrections within its phase. Read its actual artifacts and final handoff before accepting it.
6. Integrate accepted commits in dependency order. Resolve mechanical conflicts; ask about conflicts that change intent.
7. Run full integrated verification and the declared reviews in the coordinator. Separate local proof from external gates.

## Boundaries

Workers may commit only assigned verified changes. Full technical access does not authorize destructive operations, credential use, push, PR creation, deployment, publication, or production mutation. Ask before every undeclared worker wave or external action.

If setup returns only a temporary client ID, creation fails persistently, title or pin setup fails persistently, permissions differ from the approved contract, or the ready task cannot be resolved unambiguously, stop and report the exact workstream. Never silently alter the approved topology.
