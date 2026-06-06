# Contributing

Thanks for looking. voice-check is part of a personal skills monorepo, but
patches and issues are welcome.

## Principles

- **Standard library only.** The deterministic core must stay dependency-free so
  it installs anywhere and runs offline. Don't add runtime dependencies.
- **Test-first.** Every behavior has a test. Add the failing test before the
  implementation.
- **Privacy.** The profiler emits aggregate statistics only — never a raw
  sentence from the corpus. Tests use synthetic fixtures, never real corpora.
- **Explainable.** The score is a transparent sum of named penalties; keep it
  that way. No black-box scoring.

## Develop

```bash
cd voice-check
pip install -e ".[dev]"
pytest
```

Or without installing:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests
```

## Layout

- `src/voice_check/` — the package (one module per responsibility).
- `scripts/` — thin wrappers over the CLI for no-install use.
- `skills/` + `commands/` — the Claude Code / Codex skill and slash command.
- `examples/` — synthetic corpus + AI contrast set (used by tests).
- `docs/` — architecture and evaluation.

## Adding a checker rule

Add a `_rule_*` function in `src/voice_check/checks.py` returning a list of
violation dicts (`rule`, `severity`, `count`, `penalty`, `message`, `fix`),
register it in `_RULES`, and add positive + negative tests in
`tests/test_checks.py`. If it should affect the score weighting, add the weight
to `DEFAULT_SCORE_WEIGHTS` in `profile.py`.
