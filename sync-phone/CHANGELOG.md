# Changelog

All notable changes to sync-phone are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] — 2026-05-20

Dual-runtime: Codex CLI support added alongside the existing Claude Code support.

### Added
- `codex/SKILL.md` — Codex-side mirror of the skill body. Same workflow as the Claude version, just lives where Codex discovers skills.
- `codex/setup.sh` — compatibility wrapper that delegates to the root installer.
- `codex/doctor.sh` — health check for the Codex install.
- `codex/agents/openai.example.yaml` — Codex interface declaration with default prompt + implicit-invocation policy.
- `codex/automation.example.toml` — optional scheduled-drain template, **INACTIVE by default**.
- Root `setup.sh` — single-command dual-runtime installer. Reads `local.env`, symlinks the Claude install, copies the Codex install, renders the automation template.
- Root `sync.sh` — push repo edits to the Codex install (no-op for Claude, which is symlinked).
- `local.env.example` — one source of truth for paths and per-runtime model preferences. `.gitignore`d when copied to `local.env`.
- `docs/CODEX-AUTOMATION.md` — how (and when) to flip the optional Codex cron on.

### Changed
- README: install section split into "marketplace" (Claude-only quickstart) and "from source" (dual-runtime). Configuration section now points at `local.env` first, with the in-SKILL.md fallback called out for marketplace installs.
- `.gitignore`: added `local.env` and the generated `config/settings.conf` so machine-specific paths never get committed.
- `SKILL.md` (Claude side, unchanged content) now has an equivalent Codex sibling. Edits to behavior must touch both files to keep the two runtimes in lockstep (or be made in `codex/SKILL.md` and propagated via `bash sync.sh`).

### Security
- No new network dependencies. The Codex cron, when activated, runs in an ephemeral worktree against the configured `cwds` only.
- `setup.sh` `chmod 600`s `local.env` and `config/settings.conf` even though they hold no secrets — defensive posture in case the user adds tokens later.

## [0.1.0] — 2026-05-17

Initial release.

### Added
- `skills/sync-phone/SKILL.md` — the core skill: read inbox, summarize, route, archive, clear.
- `commands/sync-phone.md` — `/sync-phone` slash command that invokes the skill.
- `.claude-plugin/plugin.json` + `marketplace.json` — Claude Code plugin distribution metadata.
- `docs/SHORTCUT-SETUP.md` — iPhone Shortcut build walkthrough.
- `docs/VAULT-SETUP.md` — vault shape requirements and minimum `CLAUDE.md` template.
- `examples/sample-vault/` — minimum working vault demonstrating the required shape.
- `examples/sample-run.md` — full end-to-end walkthrough of one drain cycle.
- README, LICENSE (MIT), `.gitignore`.
