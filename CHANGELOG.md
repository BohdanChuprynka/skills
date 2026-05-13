# Changelog

All notable changes to dream-skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `apply_auto.py` now keeps vault `wiki/index.md` files in sync. After each applied edit, the page is appended to its subdir's index file if not already linked. Idempotent against both markdown links and Obsidian `[[wikilinks]]`, so curated descriptions are preserved.
- New flags: `--index-file <path>` (override auto-discovery) and `--no-index-update` (disable entirely). New env var: `DREAM_INDEX_FILE`.
- `apply_undo.sh` now reverts vault index edits alongside page edits when undoing a full cycle.
- README compatibility note: dream-skill is tested only against Claude Code; other agent runtimes are not verified.

## [0.1.0] - 2026-05-13

Initial public release.

### Added
- Four-stage reconcile pipeline: session preprocess, vault snapshot, Claude reconcile call, manual apply.
- `dream.sh` orchestrator with `--dry-run`, `--since <window>`, and `--model <id>` flags.
- `scripts/preprocess.py` — filters `~/.claude/projects/*.jsonl` session logs into a user-biased signal transcript.
- `scripts/load_vault_state.py` — walks a markdown vault, extracts frontmatter (`status`, `updated`, `needs_verification`), titles, sections.
- `scripts/apply_auto.py` — reads accepted proposals from a dream report and writes them to the vault, logging every edit to `.apply-log.jsonl`.
- `scripts/apply_undo.sh` — reverts any cycle by date, using the apply log.
- `setup.sh` interactive wizard for first-run configuration.
- MCP isolation pattern: dream.sh launches Claude with `--mcp-config <skill>/config/mcp-config.json --strict-mcp-config` so daily sessions stay unaffected.
- Tier 0 (zero MCPs) works on every machine.
- Tier 1 (Filesystem MCP for a sandboxed inbox folder) and Tier 2 (Notion / Gmail / Calendar MCPs, each independently optional) documented in `docs/MCP-SETUP.md`.
- Plugin manifests (`plugin.json`, `marketplace.json`) for distribution via `/plugin marketplace add`.
- MIT license, contributor guide, GitHub issue and PR templates.

### Notes
- Cost on Sonnet 4.6 with prompt caching: ~$0.10 per cycle in steady state. First-run higher because the cache is cold.
- No autonomous firing. The user explicitly invokes `dream.sh`.
- No automated test harness in this release; testing is manual report-review.

[Unreleased]: https://github.com/BohdanChuprynka/dream-skill/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/BohdanChuprynka/dream-skill/releases/tag/v0.1.0
