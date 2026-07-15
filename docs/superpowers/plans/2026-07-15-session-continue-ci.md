# Session Continue CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic cross-platform GitHub Actions coverage for the existing `session-continue` test suite.

**Architecture:** A single path-filtered workflow owns CI for `session-continue`. It runs the repository's existing Node test command across Ubuntu and macOS on Node.js 22 and 24 without adding dependencies or changing runtime code.

**Tech Stack:** GitHub Actions, `actions/checkout@v4`, `actions/setup-node@v4`, Node.js built-in test runner

## Global Constraints

- Trigger only when `session-continue/**` or `.github/workflows/session-continue-ci.yml` changes.
- Test on `ubuntu-latest` and `macos-latest`.
- Test Node.js 22 and 24.
- Set `fail-fast: false` so every matrix environment reports its result.
- Do not modify or stage the existing `dream-skill` or `meetily-context` worktree changes.
- Do not add package dependencies or change `session-continue` production code.

---

### Task 1: Add the session-continue CI workflow

**Files:**
- Create: `.github/workflows/session-continue-ci.yml`
- Test: `session-continue/tests/session-continue.test.mjs`

**Interfaces:**
- Consumes: the existing command `node --test session-continue/tests/session-continue.test.mjs`
- Produces: a GitHub Actions workflow with four matrix jobs covering two operating systems and two Node.js LTS lines

- [ ] **Step 1: Verify the existing test baseline**

Run:

```bash
node --test session-continue/tests/session-continue.test.mjs
```

Expected: 22 tests pass, 0 fail.

- [ ] **Step 2: Create the workflow**

Create `.github/workflows/session-continue-ci.yml` with exactly:

```yaml
name: session-continue CI

on:
  push:
    paths:
      - "session-continue/**"
      - ".github/workflows/session-continue-ci.yml"
  pull_request:
    paths:
      - "session-continue/**"
      - ".github/workflows/session-continue-ci.yml"

jobs:
  test:
    name: Node ${{ matrix.node }} on ${{ matrix.os }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        node: ["22", "24"]

    steps:
      - name: Check out repo
        uses: actions/checkout@v4

      - name: Set up Node ${{ matrix.node }}
        uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}

      - name: Run session-continue tests
        run: node --test session-continue/tests/session-continue.test.mjs
```

- [ ] **Step 3: Validate the workflow syntax**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/session-continue-ci.yml"); puts "YAML OK"'
```

Expected: `YAML OK`.

- [ ] **Step 4: Re-run the test suite**

Run:

```bash
node --test session-continue/tests/session-continue.test.mjs
```

Expected: 22 tests pass, 0 fail.

- [ ] **Step 5: Verify contribution isolation**

Run `git diff --check -- .github/workflows/session-continue-ci.yml`, `git status --short`, and `git diff --cached --name-only`.

Expected: no whitespace errors; only the workflow and plan are selected for the implementation commit; pre-existing `dream-skill` and `meetily-context` changes remain unstaged.

- [ ] **Step 6: Commit the workflow**

```bash
git add -- .github/workflows/session-continue-ci.yml docs/superpowers/plans/2026-07-15-session-continue-ci.md
GIT_AUTHOR_DATE='2026-07-15T12:15:00-04:00' GIT_COMMITTER_DATE='2026-07-15T12:15:00-04:00' git commit -m "ci: test session-continue across supported Node versions"
```

Expected: one commit containing only the workflow and implementation plan, with author and committer dates on July 15, 2026.

- [ ] **Step 7: Push and verify GitHub Actions**

Run `git push origin main`.

Expected: `origin/main` advances to the new workflow commit and GitHub starts the `session-continue CI` workflow.
