# Contributing to transcribe-audio

This is a personal tool, but PRs and issues are welcome — especially if you use it.

## Local development

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/transcribe-audio
uv venv
source .venv/bin/activate
uv pip install -e ".[dev]"
```

After editing source, your installed `transcribe-audio` binary already points at the live source (because of `uv tool install` editable mode), so reinstall is not needed for most changes.

## Tests

```bash
uv run --extra dev pytest -v
```

The test suite mocks all OpenAI HTTP calls via `respx`. No API key needed to run tests. A small `tests/fixtures/short_test.mp3` is used for chunking + probe tests.

To run with coverage:

```bash
uv run --extra dev pytest --cov=transcribe_audio --cov-report=term-missing
```

## Linting + formatting

```bash
uv run --extra dev ruff format src tests
uv run --extra dev ruff check src tests
```

## Adding a new summary style

1. Create `src/transcribe_audio/templates/summary_styles/<name>.txt` with the system prompt.
2. Optionally extend the `Literal` type in `config.py` to make it autocompletable in `init`.
3. Add a test in `tests/test_summarize.py` that mocks the OpenAI response and asserts the template is selected.

## Adding a new output format

1. Add a method on `TranscriptionResult` in `transcribe.py` (e.g. `to_xml()`).
2. Add a branch in `cli.transcribe()` under the `format_set` handling.
3. Add to the `--formats` help string.

## Architecture decisions

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the why behind library/CLI/skill layering, chunking strategy, and config layering.

## Reporting issues

Issues live on the monorepo: [github.com/BohdanChuprynka/skills/issues](https://github.com/BohdanChuprynka/skills/issues). Prefix the title with `[transcribe-audio]` so it's filterable.
