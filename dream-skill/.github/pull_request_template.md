## Summary

One or two sentences. What this changes and why.

## Type of change

- [ ] Bug fix (non-breaking)
- [ ] New feature (non-breaking)
- [ ] Breaking change (behavior or output format)
- [ ] Docs / examples / chores
- [ ] Prompt change (reconcile system or user template)

## Test plan

How you verified the change works. For pipeline or prompt changes, include before/after report excerpts from a test vault.

- [ ] Ran `./dream.sh --dry-run` against a test vault — no errors.
- [ ] Ran `./dream.sh` end-to-end — report rendered correctly.
- [ ] If apply logic changed: ran `apply_auto.py --apply`, verified writes, ran `apply_undo.sh` to confirm rollback works.
- [ ] If Python scripts changed: ran them standalone with sample inputs.

## Before / after (prompt or report changes only)

<details>
<summary>Before</summary>

```markdown
paste the relevant report section as it was
```

</details>

<details>
<summary>After</summary>

```markdown
paste the same section after your change
```

</details>

One sentence on why the new output is better.

## Checklist

- [ ] One concern per PR.
- [ ] Title uses Conventional Commits (`feat:`, `fix:`, `docs:`, etc.).
- [ ] No personal data committed (no real vault paths, sessions, or MCP tokens).
- [ ] [CHANGELOG.md](../CHANGELOG.md) updated under `[Unreleased]` if user-visible.
- [ ] [CONTRIBUTING.md](../CONTRIBUTING.md) sources-of-truth table is still accurate after this change.
