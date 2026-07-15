# Session Continue CI Design

## Goal

Automatically run the existing `session-continue` test suite when its code or CI configuration changes, so regressions are caught before merge.

## Approach

Add one GitHub Actions workflow at `.github/workflows/session-continue-ci.yml`.

The workflow will:

- run for pushes and pull requests that touch `session-continue/**` or the workflow itself;
- test on Ubuntu and macOS, matching the skill's documented platform support;
- test Node.js 22 and 24, the supported LTS release lines as of July 2026;
- use `actions/checkout@v4` and `actions/setup-node@v4`;
- run `node --test session-continue/tests/session-continue.test.mjs` without installing dependencies.

## Data Flow

A matching repository change triggers four independent jobs from the operating-system and Node-version matrix. Each job checks out the repository, selects its Node version, and runs the committed 22-test suite. Any failing test makes that matrix job and the overall workflow fail.

## Failure Handling

GitHub Actions will preserve each job's test output. The matrix will use `fail-fast: false` so one failure does not hide results from the other supported environments.

## Verification

Before committing the workflow:

1. Run the existing test command locally and confirm all 22 tests pass.
2. Parse the workflow as YAML locally.
3. Recheck the diff and staged file list to ensure no existing `dream-skill` or `meetily-context` work is included.

No production code, test behavior, or installation flow changes in this contribution.
