# Changelog

All notable changes to voice-check are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/). Semantic versioning.

## [Unreleased]

### Changed
- Skill and slash command now report the findings and then **immediately deliver
  the rewritten draft** in the user's voice, instead of rewriting only when asked.
  The only things that stop the auto-rewrite: out-of-scope input (code/docs), or a
  fix that would require fabricating facts (apply the honest version and flag what
  to verify).

## [0.1.0] - 2026-06-06

Initial release.

### Added
- Deterministic, standard-library-only voice-profiling package (`voice_check`).
- `voice-check` CLI with four subcommands: `profile`, `check`, `build-skill`, `eval`.
- Corpus loader for `.txt` / `.md` / `.jsonl` / `.csv` with kind detection
  (raw speech / polished writing / edited revision).
- Voice profile with a spoken-vs-written modeling split; emits
  `profile_stats.json`, `voice_rules.json`, `voice_profile.md` (aggregate
  statistics only — no raw sentences).
- Explainable 0–100 draft checker: em dashes, corporate words, generic-AI tells,
  spoken filler, sentence-length drift, missing contractions, uniform rhythm,
  inflated claims. Every point is attributable to a named rule.
- Mechanical baseline rewriter (safe, deterministic, idempotent).
- ROC-AUC evaluation harness with independent and content-matched negatives, plus
  a before/after rewrite demo. Aggregate metrics only.
- Claude Code + Codex skill and slash command; idempotent `setup.sh` installer;
  Claude Code plugin/marketplace manifests.
- 78 tests; synthetic example corpus + AI contrast set for a data-free CI proof.
