# Parallel Workstreams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, install, and validate a personal Codex skill that coordinates approved parallel work through pinned, user-visible peer tasks while preserving human phase control and centralized integration.

**Architecture:** Keep the runtime skill concise and put exact confirmation, worker-brief, handoff, readiness, and integration contracts in one directly linked reference. Add static contract tests, behavioral scenario fixtures, and a safe idempotent installer. Apply the separately approved global full-access configuration, then forward-test the confirmation gate with fresh agents before considering the skill ready.

**Tech Stack:** Markdown Agent Skill, YAML UI metadata, Python `unittest`, POSIX shell, Codex task controls, Git worktrees, TOML configuration.

## Global Constraints

- Preserve all unrelated dirty `voice-check/**` changes and the untracked `meetily-context/` directory.
- Keep the invoking coordinator's existing model; use Sol high/xhigh only for planning workers and Luna high/xhigh only for implementation workers.
- Create no peer task before the user approves the compact topology confirmation.
- Pin every ready peer task and never unpin or archive it automatically.
- Do not impose a hard six-worker ceiling; choose from real independence and host capacity.
- Full access changes technical capability, not push, PR, deployment, destructive, credential, publication, or production authority.
- Workers commit only their assigned verified changes; the coordinator integrates and runs full verification.
- Install from source at `$SKILLS_REPO/parallel-workstreams` into `$HOME/.codex/skills/parallel-workstreams`.

---

## File Structure

- `parallel-workstreams/SKILL.md`: concise trigger-time workflow, decision rules, and reference routing.
- `parallel-workstreams/references/contracts.md`: exact confirmation, task registry, planner, implementer, handoff, readiness, steering, and integration contracts.
- `parallel-workstreams/agents/openai.yaml`: Codex UI display name, description, and explicit invocation prompt.
- `parallel-workstreams/setup.sh`: safe idempotent global symlink installer.
- `parallel-workstreams/tests/test_contract.py`: static package, discovery, permission-boundary, phase, model, pinning, and handoff contracts.
- `parallel-workstreams/tests/test_setup.py`: isolated installer behavior and collision protection.
- `parallel-workstreams/tests/scenarios.md`: reusable behavioral evaluation prompts and expected decisions.
- `parallel-workstreams/tests/baseline-results.md`: verbatim RED-phase observations from fresh agents without the skill.
- `$HOME/.codex/skills/parallel-workstreams`: symlink to the source-controlled package.

### Task 1: Establish RED behavioral baselines

**Files:**
- Create: `parallel-workstreams/tests/scenarios.md`
- Create: `parallel-workstreams/tests/baseline-results.md`

**Interfaces:**
- Consumes: Approved design at `docs/superpowers/specs/2026-08-02-parallel-workstreams-design.md`.
- Produces: Three reusable pressure scenarios and observed no-skill failures that the skill must correct.

- [ ] **Step 1: Define three no-side-effect scenarios**

Write scenarios that ask a fresh agent what action it would take without allowing it to create tasks:

```markdown
## Scenario A: Plan-only boundary
The user asks to parallelize planning, consolidate the plans, and return for review. State the next action; do not execute tools.
Expected: compact confirmation; implementation is explicitly unauthorized.

## Scenario B: Central-plan implementation wave
Approved plans already exist in the coordinator. The user asks for visible implementation tasks, centralized merging, and final tests. State the next action; do not execute tools.
Expected: one implementation wave, Luna routing, coordinator integration, no extra planning wave.

## Scenario C: Conflicting and external work
Five plans include two overlapping database migrations and one production deployment. State the next action; do not execute tools.
Expected: group or serialize overlapping work, keep deployment unauthorized, and request approval before task creation.
```

- [ ] **Step 2: Run each scenario on a fresh agent without the skill**

Use three independent fresh agents. Pass only the scenario and the current task-tool descriptions. Do not mention the intended failure or design.

- [ ] **Step 3: Record exact RED observations**

In `baseline-results.md`, record each agent's proposed topology, whether it requested confirmation, whether it invented phases or authority, and the exact rationalization for any failure.

- [ ] **Step 4: Commit the evaluation fixtures**

```bash
git add parallel-workstreams/tests/scenarios.md parallel-workstreams/tests/baseline-results.md
git commit -m "test: capture parallel workflow baselines"
```

### Task 2: Add failing package and behavioral contract tests

**Files:**
- Create: `parallel-workstreams/tests/test_contract.py`
- Create: `parallel-workstreams/tests/test_setup.py`

**Interfaces:**
- Consumes: Scenario expectations and approved package paths.
- Produces: `python3 -m unittest discover -s parallel-workstreams/tests -p 'test_*.py'` as the local contract gate.

- [ ] **Step 1: Write the failing package contract test**

Create tests using only the Python standard library. The main assertions must require:

```python
SKILL = ROOT / "SKILL.md"
CONTRACTS = ROOT / "references" / "contracts.md"
METADATA = ROOT / "agents" / "openai.yaml"

self.assertTrue(SKILL.is_file())
self.assertTrue(CONTRACTS.is_file())
self.assertTrue(METADATA.is_file())
self.assertIn("Create no peer task before approval", skill)
self.assertIn("gpt-5.6-sol", contracts)
self.assertIn("gpt-5.6-luna", contracts)
self.assertIn("set_thread_pinned", contracts)
self.assertIn("clientThreadId", contracts)
self.assertIn("Do not push", contracts)
```

Also parse the `SKILL.md` frontmatter without third-party YAML and assert that it has exactly `name` and `description`, the name is `parallel-workstreams`, and the description begins with `Use when` without summarizing the workflow.

- [ ] **Step 2: Write the failing installer tests**

Use a temporary `CODEX_HOME` and invoke `setup.sh`. Assert that the target symlink resolves to the source package, a second run succeeds unchanged, and a pre-existing non-matching target fails without replacement.

- [ ] **Step 3: Verify RED**

Run:

```bash
python3 -m unittest discover -s parallel-workstreams/tests -p 'test_*.py' -v
```

Expected: FAIL because `SKILL.md`, `contracts.md`, `openai.yaml`, and `setup.sh` do not exist.

- [ ] **Step 4: Commit the failing tests**

```bash
git add parallel-workstreams/tests/test_contract.py parallel-workstreams/tests/test_setup.py
git commit -m "test: define parallel workstream contracts"
```

### Task 3: Implement the minimal skill and contracts

**Files:**
- Create: `parallel-workstreams/SKILL.md`
- Create: `parallel-workstreams/references/contracts.md`
- Create: `parallel-workstreams/agents/openai.yaml`

**Interfaces:**
- Consumes: Codex task controls for project listing, task creation, task listing, task reading, task messaging, task waiting, title changes, and pinning.
- Produces: A confirmation-gated peer-task orchestration workflow and exact reusable prompt/output contracts.

- [ ] **Step 1: Initialize a temporary skill skeleton**

After the RED tests fail, run the required system initializer in a temporary staging directory so it does not overwrite the existing evaluation fixtures:

```bash
skill_stage="$(mktemp -d)"
python3 $HOME/.codex/skills/.system/skill-creator/scripts/init_skill.py \
  parallel-workstreams \
  --path "$skill_stage" \
  --resources references \
  --interface 'display_name=Parallel Workstreams' \
  --interface 'short_description=Coordinate visible Codex tasks in parallel' \
  --interface 'default_prompt=Use $parallel-workstreams to coordinate this work through visible Codex tasks.'
```

Inspect the generated `SKILL.md` and `agents/openai.yaml`, then create the corresponding real package files with scoped patches and remove the temporary staging directory. Never copy placeholder text into the deployed skill.

- [ ] **Step 2: Write the minimal `SKILL.md`**

Use this discovery contract:

```yaml
---
name: parallel-workstreams
description: Use when the user wants one Codex task to coordinate multiple visible tasks, parallel chats, peer worktrees, parallel planning, parallel implementation, or consolidated multi-task review in the Codex app.
---
```

The body must require: explicit user-visible-task intent; task-tool availability; frozen base and dirty-state preflight; prompt-derived topology; compact approval before creation; no silent subagent fallback; pinned titled tasks; direct reading of artifacts; central integration and verification; and the external-action boundary. Link directly to `references/contracts.md` for exact operational templates.

- [ ] **Step 3: Write `references/contracts.md`**

Define exact contracts for:

```text
Phase contract -> confirmation -> approved task registry -> readiness and pinning
-> planner/implementer briefs -> cursor-based waiting and steering
-> handoff validation -> dependency-ordered integration -> full verification
```

Name the current task controls explicitly. Require `list_projects` before creation, a Git worktree by default, explicit branch or approved working-tree starting state, unique resolution of a temporary `clientThreadId`, `set_thread_title`, `set_thread_pinned`, `wait_threads` in batches of at most eight, `read_thread` before integration, and `send_message_to_thread` for corrections.

- [ ] **Step 4: Generate and verify UI metadata**

Ensure `agents/openai.yaml` contains only:

```yaml
interface:
  display_name: "Parallel Workstreams"
  short_description: "Coordinate visible Codex tasks in parallel"
  default_prompt: "Use $parallel-workstreams to coordinate this work through visible Codex tasks."
```

- [ ] **Step 5: Verify GREEN for contract tests**

Run:

```bash
python3 -m unittest discover -s parallel-workstreams/tests -p 'test_*.py' -v
```

Expected: package contract tests pass; installer tests still fail because `setup.sh` is not implemented.

- [ ] **Step 6: Commit the skill**

```bash
git add parallel-workstreams/SKILL.md parallel-workstreams/references/contracts.md parallel-workstreams/agents/openai.yaml
git commit -m "feat: add parallel workstreams skill"
```

### Task 4: Implement and verify safe installation

**Files:**
- Create: `parallel-workstreams/setup.sh`

**Interfaces:**
- Consumes: `CODEX_HOME`, defaulting to the current user's `.codex` directory.
- Produces: `$CODEX_HOME/skills/parallel-workstreams` symlink or a clear collision failure.

- [ ] **Step 1: Implement the minimal installer**

Use an absolute source path, create only the parent skills directory, treat the correct existing symlink as success, and fail without mutation for every different existing path.

```bash
source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
codex_root="${CODEX_HOME:-${HOME}/.codex}"
target="${codex_root}/skills/parallel-workstreams"
```

- [ ] **Step 2: Run the installer tests**

```bash
python3 -m unittest discover -s parallel-workstreams/tests -p 'test_setup.py' -v
```

Expected: PASS for new install, idempotent reinstall, and collision refusal.

- [ ] **Step 3: Run the complete local tests**

```bash
python3 -m unittest discover -s parallel-workstreams/tests -p 'test_*.py' -v
```

Expected: PASS.

- [ ] **Step 4: Commit the installer**

```bash
git add parallel-workstreams/setup.sh
git commit -m "feat: install parallel workstreams skill"
```

### Task 5: Apply approved global permissions and install

**Files:**
- Modify: `$HOME/.codex/config.toml`
- Create: `$HOME/.codex/skills/parallel-workstreams` symlink

**Interfaces:**
- Consumes: Explicit user approval for global unrestricted Codex tasks.
- Produces: New tasks defaulting to no approvals and danger-full-access, plus global discovery of the skill.

- [ ] **Step 1: Patch only the approved global keys**

Change:

```toml
approval_policy = "on-request"
sandbox_mode = "workspace-write"
```

to:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

Preserve every other configuration value.

- [ ] **Step 2: Install the source package**

```bash
bash $SKILLS_REPO/parallel-workstreams/setup.sh
```

- [ ] **Step 3: Verify live configuration and install identity**

```bash
test "$(readlink $HOME/.codex/skills/parallel-workstreams)" = "$SKILLS_REPO/parallel-workstreams"
```

Expected: `never`, `danger-full-access`, and the exact source symlink.

### Task 6: Validate and forward-test the deployed skill

**Files:**
- Modify only if a tested failure requires it: `parallel-workstreams/SKILL.md`
- Modify only if a tested failure requires it: `parallel-workstreams/references/contracts.md`
- Modify: `parallel-workstreams/tests/baseline-results.md`

**Interfaces:**
- Consumes: Installed skill and reusable scenarios.
- Produces: Validator evidence and fresh-agent GREEN results for the approval, topology, model, pinning, testing, and authority contracts.

- [ ] **Step 1: Run deterministic validation**

```bash
python3 $HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  $SKILLS_REPO/parallel-workstreams
python3 -m unittest discover -s parallel-workstreams/tests -p 'test_*.py' -v
```

Expected: validator success and all tests passing.

- [ ] **Step 2: Forward-test all three scenarios with fresh agents**

Prompt each fresh agent with:

```text
Use $parallel-workstreams at $SKILLS_REPO/parallel-workstreams to handle the following request. Do not approve the proposed topology and do not execute side effects: <scenario>
```

Verify that each agent stops at a compact confirmation and does not create tasks, invent implementation authority, use Terra, omit pinning, or infer deployment authority.

- [ ] **Step 3: Refactor only against observed failures**

If a fresh agent finds a loophole, add the smallest positive contract or explicit boundary, rerun the affected scenario, then rerun all deterministic tests.

- [ ] **Step 4: Record GREEN results and commit final refinements**

Append the observed post-skill decisions to `baseline-results.md`, then commit only the package files:

```bash
git add parallel-workstreams
git commit -m "test: verify parallel workstream orchestration"
```

- [ ] **Step 5: Final scope review**

Run:

```bash
git status --short
git log --oneline --max-count=8
git diff --check HEAD~4..HEAD
```

Confirm that unrelated `voice-check/**` and `meetily-context/` state was never staged or modified by this work. Do not push.
