# Contributing to dream-skill

Thanks for considering a contribution. The repo is small and the surface area is intentionally narrow — most useful changes are in the skill body, the Python scripts, or the reconcile prompt. Read this first to find the right file.

## Quick orientation

dream-skill is a single Claude Code skill plus a small pipeline of Python scripts. The plugin manifest (`.claude-plugin/`) is what Claude Code loads. The skill body lives at `skills/dream-skill/SKILL.md`. Everything else supports those two surfaces: scripts that prepare inputs from local Claude/Codex conversations, prompts that drive the reconcile call, configs that the user customizes.

Behavior changes should land in source-of-truth files at the top of the table below. Documentation changes should land in `docs/` or `README.md`. Avoid touching generated or mirrored content.

## What to edit (sources of truth)

| I want to change... | Edit this file |
|---|---|
| What the skill does conceptually, when it triggers, frontmatter | `skills/dream-skill/SKILL.md` |
| The reconcile system prompt | `prompts/system.md` |
| The reconcile user-message template | `prompts/reconcile.md` |
| Conversation preprocessing (Claude/Codex JSONL filter, signal extraction) | `scripts/preprocess.py` |
| Vault snapshot (frontmatter walker, file discovery) | `scripts/load_vault_state.py` |
| Apply logic (write proposals to vault, log edits) | `scripts/apply_auto.py` |
| Rollback logic | `scripts/apply_undo.sh` |
| Pipeline orchestration, CLI flags, MCP loading | `dream.sh` |
| Signal keyword regex, channel weights | `config/signal-patterns.toml` |
| Default vault categories | `config/vault-paths.toml` |
| MCP server templates | `config/mcp-config.example.json` |
| Plugin metadata (name, description, version) | `.claude-plugin/plugin.json` |
| Marketplace listing | `.claude-plugin/marketplace.json` |
| Public docs (user-facing setup, MCP walkthroughs) | `docs/*.md` |
| README structure or copy | `README.md` |
| Changelog entries | `CHANGELOG.md` |

If you find yourself editing two files for one logical change, that's a sign the file boundaries are wrong — please open an issue first.

## What NOT to edit

- `.apply-log.jsonl`, `.usage-log.jsonl` — runtime artifacts, never committed.
- `mcp-config.json` (without `.example.`) — local config, gitignored. The committed file is `config/mcp-config.example.json`.
- Anything under `dream-reports/` — those are user output.

## Local dev loop

```bash
# 1. clone
git clone https://github.com/BohdanChuprynka/dream-skill
cd dream-skill

# 2. install as a local plugin
/plugin marketplace add "$(pwd)"
/plugin install dream-skill@dream-skill-marketplace

# 3. run the setup wizard against a test vault
DREAM_VAULT_ROOT=/tmp/dream-test-vault ./setup.sh

# 4. seed the test vault with a few markdown files + frontmatter
mkdir -p /tmp/dream-test-vault/persona
cat > /tmp/dream-test-vault/persona/role.md <<'EOF'
---
status: active
updated: 2025-11-01
---
# Role
Engineer at Acme Corp.
EOF

# 5. dry run
./dream.sh --dry-run

# 6. real run (costs ~$0.10)
./dream.sh

# 7. inspect the report
open "/tmp/dream-test-vault/dream-reports/dream-$(date +%F).md"
```

Iterate by editing the file in the source-of-truth table, re-running `./dream.sh --dry-run` to see the prompt payload, and `./dream.sh` to see the new report shape.

## Testing a skill change

There is no automated test harness. The skill is tested by running it and reading the report. When you change behavior, include in your PR description:

1. The test vault layout you used (a short tree dump is fine).
2. The report you got before the change.
3. The report you got after the change.
4. One sentence on why the new report is better.

For changes to `preprocess.py`, `apply_auto.py`, or `load_vault_state.py` (pure Python, no LLM call), unit tests are expected when behavior changes. Put them under `tests/` and run with `python -m unittest`.

## Commit style

Conventional Commits for the subject line. Keep it under 72 chars.

```
feat(reconcile): add Notion page evidence to needs-confirmation bucket
fix(apply): preserve frontmatter ordering when writing back updated keys
docs(readme): clarify tier 0 vs tier 1 vs tier 2 MCP model
chore(deps): bump example MCP server versions in mcp-config.example.json
```

One concern per commit, one concern per PR. A docs typo and an apply-logic fix go in two separate PRs.

## Pull request checklist

- [ ] One concern per PR.
- [ ] Title in Conventional Commits format.
- [ ] If you changed the reconcile prompt, include before/after report excerpts.
- [ ] If you changed Python scripts, run them once against a test vault and confirm no regressions.
- [ ] No personal data committed — no real vault paths, no real session logs, no MCP tokens.
- [ ] CHANGELOG.md updated under `[Unreleased]` if user-visible.

## Code of conduct

Be straight, be precise, and assume the other person is acting in good faith. If you wouldn't say it in a meeting at a job you wanted to keep, don't say it on the PR.
