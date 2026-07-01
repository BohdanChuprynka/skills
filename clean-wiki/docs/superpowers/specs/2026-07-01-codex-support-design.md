# Clean-Wiki Codex Support Design

## Context

Clean-Wiki currently works as a Claude Code skill. The only deterministic runtime component is the local Flask review UI in `skills/clean-wiki/scripts/serve.py`; scan, queue merge, approval application, and undo-log writing are agent-orchestrated from `skills/clean-wiki/SKILL.md`.

Codex supports local skills from `~/.codex/skills`, repo skills from `.agents/skills`, optional `agents/openai.yaml` UI metadata, and plugin distribution through `.codex-plugin/plugin.json`. The repo already uses setup scripts for dual-runtime skills such as `session-continue` and `voice-check`.

## Product Plan

Recommended approach: make Clean-Wiki a dual-runtime local skill, with one shared skill implementation and platform-specific install guidance.

1. Add a root `setup.sh` for Clean-Wiki.
   - Keep Claude Code install as a symlink to `~/.claude/skills/clean-wiki`.
   - Always install Codex by copying a sanitized inner skill folder to `~/.codex/skills/clean-wiki`, matching existing dual-runtime repo conventions even when Codex has not created `~/.codex` yet.
   - Exclude runtime/private artifacts from the Codex copy: `data/`, `.venv/`, `.pytest_cache/`, `logs/`, `*.log`, `reports/`, and `config/vault-paths.toml`.
   - Create a `.venv` and `config/vault-paths.toml` in each runtime location that needs them: the repo skill for Claude/direct usage and the copied Codex skill for Codex usage.
   - Copy `config/vault-paths.example.toml` to `config/vault-paths.toml` only if the real config is absent; if the repo config already exists, copy it deliberately into the Codex-local config on first Codex install. On reruns, preserve an existing Codex-local config and runtime `data/`, `logs/`, and `reports/` before refreshing the copied skill.
   - Warn when `vault-paths.toml` still contains `/ABSOLUTE/PATH/` placeholders.
   - Print usage for Claude (`/clean-wiki`) and Codex (`Use $clean-wiki to audit my Obsidian vaults.`), plus the Codex restart requirement.

2. Update the skill instructions to be agent-neutral with explicit Claude/Codex mappings.
   - Replace Claude-only language with "orchestrating agent" where behavior is shared.
   - Map `AskUserQuestion` to a normal concise user question in Codex, `Agent` to Codex subagent tooling when available, and `Edit` to Codex file edits.
   - Preserve the existing JSON queue schema, safety rules, one-subagent-per-vault model, review UI flow, and apply/undo contract.
   - For Codex, instruct the agent to use available subagent tooling when exposed; if subagents are not available, scan selected vaults sequentially and disclose that limitation before continuing.
   - Resolve `skill_dir` before reading config or writing queue/decision/undo files, and launch the review UI through that resolved skill directory instead of assuming the current working directory contains `clean-wiki.sh`.

3. Add Codex skill metadata.
   - Create `skills/clean-wiki/agents/openai.yaml` with display name, short description, default prompt, and implicit invocation policy.
   - Keep dependencies empty because the skill does not require MCP or app connectors.

4. Add optional Codex plugin packaging metadata.
   - Create `.codex-plugin/plugin.json` so Clean-Wiki can later be installed through a Codex marketplace or local plugin flow.
   - Keep setup as the primary install path because Python dependencies and local config are outside the plugin manifest.

5. Update documentation.
   - README should describe both Claude and Codex install paths.
   - README should make the setup script the recommended path.
   - README should explain direct UI launch, full agent flow, local config, and privacy behavior for both agents.
   - Monorepo README should move Clean-Wiki from "symlink install" to "setup-script install".

## Alternatives Considered

1. Plain `~/.codex/skills` copy only.
   - Pros: smallest change and matches Codex discovery.
   - Cons: weaker distribution story and no Codex UI metadata.

2. Codex plugin only.
   - Pros: aligns with marketplace distribution.
   - Cons: does not solve Python dependency setup or real vault config, so users could install the skill and still fail at runtime.

3. Rewrite scan/apply as a deterministic CLI.
   - Pros: less agent-dependent and more testable.
   - Cons: changes the core product, expands scope, and duplicates what the agent already does well.

## Clean-Wiki Functionality Plan For Codex

Codex should execute the same end-to-end flow Claude currently does:

1. Resolve `skill_dir` and read `$skill_dir/config/vault-paths.toml`.
2. Ask which configured vaults to scan.
3. For each selected vault, read the vault `AGENTS.md`, `wiki/index.md`, and relevant wiki pages.
4. Detect cleanup candidates: stale facts, contradictions, broken wikilinks, index drift, frontmatter drift, stale active pages, duplicate or superseded pages, and orphaned pages.
5. Merge findings into `$skill_dir/data/cleanup-queue.json` while preserving deferred or undecided carryover entries.
6. Locate the installed or repo-local `clean-wiki.sh` and launch it, which starts the local review UI.
7. Wait until the user finishes review and the server writes `data/decisions.json`.
8. Apply only approved decisions with normal file edits and write `data/undo-log.jsonl` before each change.
9. Report applied changes, failures, deferred decisions, and the undo path.

Codex-specific differences:

- Use `$clean-wiki` or explicit skill selection instead of Claude slash-command invocation.
- Restart Codex after `setup.sh`, because Codex scans local skills at startup.
- Use Codex subagent tooling when available. If not available, perform the vault scans sequentially with the same schema and safety properties.

## Safety And Privacy

- Never write to vault files before browser approval.
- Never apply rejected or deferred decisions.
- Never delete files permanently; archive/move only when approved.
- Keep real vault paths, queue data, decisions, reports, venvs, and runtime logs gitignored.
- Keep files, config, runtime queues, and the review UI local. The active agent provider may receive vault text in model context while scanning; do not use this skill on vaults whose contents should not be read by the active Claude/Codex provider.

## Test Strategy

- Keep existing Flask API tests passing.
- Add static/behavioral tests for Codex support artifacts:
  - `setup.sh` exists, is executable, installs Codex by copying a sanitized skill directory, creates per-location venv/config, preserves existing repo and Codex-local config, and does not copy runtime/private files.
  - `agents/openai.yaml` has the required interface metadata and default prompt.
  - `.codex-plugin/plugin.json` points to `./skills`.
  - `SKILL.md` documents both Claude and Codex flows.
  - README documents Codex setup and usage.
