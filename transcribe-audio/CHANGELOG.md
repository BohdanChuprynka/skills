# Changelog

All notable changes to this skill are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-05-25

### Added
- Initial release.
- `transcribe-audio` Python CLI (Typer-based) installable via `uv tool install`.
- Whisper API transcription with auto-chunking for files >24 MB (parallel chunk uploads, segment-offset stitching).
- Initial-prompt priming for proper nouns and technical vocabulary.
- Optional LLM summarization with three built-in styles: `brief`, `detailed`, `action_items`. Custom template files also supported.
- Optional Obsidian note export with configurable frontmatter, inbox subdirectory, and filename pattern.
- Multi-language support — Whisper handles `en`, `uk`, `ru`, and code-switching natively.
- Cost estimation printed before each run. Confirmation prompt for files >30 min.
- Output formats: `.txt`, `.srt`, `.vtt`, `.json` (with word-level segment timestamps).
- `transcribe-audio init` — interactive setup wizard.
- `transcribe-audio config show` / `config path`.
- Layered config: env (.env) → `~/.config/transcribe-audio/config.yaml` → CLI flags.
- Claude Code skill (`/transcribe-audio`) wrapping the CLI with smart language/prompt selection.
- `setup.sh` — idempotent installer that wires the CLI, skill, and slash command.
