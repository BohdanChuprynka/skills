# Architecture

## Three-layer design

```
┌──────────────────────────────────────────────────────────┐
│  Layer 3 — Claude Code skill                             │
│  Thin wrapper. Triggers on phrases. Calls CLI via Bash.  │
│  Adds judgment the CLI cannot make:                      │
│    - which language to bias toward                       │
│    - which technical vocab to prime                      │
│    - whether result belongs in a specific vault page     │
└────────────────────────┬─────────────────────────────────┘
                         │ shell exec
                         ▼
┌──────────────────────────────────────────────────────────┐
│  Layer 2 — CLI (`transcribe-audio ...`)                  │
│  Typer-based. Commands: transcribe, summarize, init,     │
│  config. Reads .env + ~/.config/transcribe-audio/        │
│  config.yaml. CLI flags override config.                 │
└────────────────────────┬─────────────────────────────────┘
                         │ python imports
                         ▼
┌──────────────────────────────────────────────────────────┐
│  Layer 1 — Python library (src/transcribe_audio/)        │
│  Pure functions. transcribe_file(), summarize_text(),    │
│  write_obsidian_note(). Each importable + unit-tested.   │
│  No CLI or skill dependencies.                           │
└──────────────────────────────────────────────────────────┘
```

Why three layers:

- **Library** is testable and embeddable. Other tools or scripts can `from transcribe_audio import transcribe_file` without dragging in CLI deps.
- **CLI** is the primary user interface for everyone — including non-Claude-Code users.
- **Skill** is a convenience layer that adds context-aware judgment from the surrounding LLM conversation. Optional; CLI works fine without it.

## Module map

```
src/transcribe_audio/
├── __init__.py          # re-exports top-level functions
├── cli.py               # Typer commands. THIN — delegates to library.
├── config.py            # Layered config loader. Pydantic-validated.
├── audio.py             # ffmpeg/ffprobe wrappers: probe, chunk, normalize
├── transcribe.py        # Whisper API calls + chunking orchestration + result types
├── summarize.py         # LLM summary against templates
├── obsidian.py          # Markdown + frontmatter writer (Jinja2 templates)
├── prompts.py           # (reserved — currently unused; for future prompt experiments)
└── templates/
    ├── obsidian_note.md.j2
    └── summary_styles/
        ├── brief.txt
        ├── detailed.txt
        └── action_items.txt
```

## Chunking strategy

OpenAI's Whisper API hard-limits each request to **25 MB**. For files at any common bitrate, this caps at roughly 40-50 minutes per request.

`audio.chunk_audio()` strategy:

1. Re-encode to a normalized format (mono, 16 kHz, 64 kbps MP3) — Whisper's preferred input shape, also produces predictable size per second (~0.48 MB/min).
2. Use ffmpeg `-f segment` to split on **time boundaries** sized to stay under the configured `chunk_size_mb` (default 24, leaving 1 MB headroom).
3. Each chunk gets a sequential filename like `<base>_chunk_000.mp3`.
4. `transcribe.transcribe_file()` probes each chunk's actual duration, computes cumulative offsets, and submits chunks to the Whisper API in parallel (default 3 concurrent).
5. Returned segments per chunk get their `start`/`end` timestamps shifted by the chunk's offset, then merged into a single sorted segment list.

**Why time-based instead of silence-based:** silence-detection chunking (pydub.split_on_silence) is theoretically nicer (avoids splitting mid-word) but is brittle on calls with constant background noise or rapid-fire turn-taking. Time-based at 50-minute boundaries with overlap-free cuts produces effectively identical transcript quality because Whisper handles boundary words gracefully via its 30-second context window.

**Trade-off:** A single word that straddles a chunk boundary may be split or transcribed twice in rare cases. This is acceptable; the alternative (silence-detection) fails silently when silences are too rare. Future improvement: 1-second overlap between chunks with de-duplication on the merge step.

## Initial prompt — the under-used lever

OpenAI's Whisper API accepts an `initial_prompt` parameter that biases the decoder. Most tools ignore it. **It is the single highest-leverage knob for transcription accuracy on technical / multilingual content.**

How it works:
- The decoder sees the prompt as if it were the previous chunk of speech.
- Proper nouns, technical terms, and language cues in the prompt make the model far more likely to correctly transcribe matching content in the audio.
- The prompt does not have to be a real previous transcript. A free-form sentence listing expected vocabulary works fine.

Example impact on a Ukrainian-English call about knowledge graphs:

```
without prompt: "Я працював із дітом анти решолшн і Семеники тапи."
with prompt:    "Я працював із entity resolution і semantic typing."
```

The skill layer generates the prompt automatically from conversation context (names mentioned, technical terms used, domain). The CLI accepts it via `--prompt "..."`.

## Config layering

```
defaults baked into Config class (pydantic)
  ↓ (overridden by)
~/.config/transcribe-audio/config.yaml
  ↓ (overridden by)
environment variables (OPENAI_API_KEY, OBSIDIAN_VAULT_PATH) [secrets only]
  ↓ (overridden by)
CLI flags (per-invocation)
```

Secrets never live in yaml — only in environment / `.env`. `write_config()` filters API keys out before writing.

## Obsidian export

`obsidian.write_obsidian_note()` is pure file I/O — does not know about routing. The Jinja2 template renders:

```
---
created: ISO timestamp
type: transcript
source: <original audio path>
duration_seconds: <float>
language: <detected ISO code>
transcribe_model: whisper-1
summary_model: gpt-4o-mini
summary_style: brief
status: unreviewed
---

# <title>

## Summary
<llm summary if present>

---

## Transcript
<full transcript text>
```

The skill layer handles *which vault* and *which subdirectory* based on content judgment. The library/CLI handle just the writing.

## Error handling philosophy

- Library functions raise typed exceptions (`RuntimeError`, `FileNotFoundError`, `ValueError`) with actionable messages.
- CLI catches at the boundary and renders user-friendly errors with Rich.
- Skill layer can recover from some errors by re-running with different flags. Most errors surface to the user.

No silent failures. No "fix later" comments.

## Testing strategy

- **`tests/test_chunking.py`** — uses real ffmpeg on a small fixture file. Asserts chunk count + offset math.
- **`tests/test_transcribe.py`** — `respx` mocks OpenAI HTTP. Validates request shape and response parsing.
- **`tests/test_obsidian.py`** — pure file I/O test. No network. Asserts frontmatter + body.
- **`tests/test_summarize.py`** — mocks OpenAI. Asserts template selection.

Integration tests that hit the real OpenAI API are not in the default suite — gate them behind `RUN_INTEGRATION=1`.

## Future extension points (v2)

- **Speaker diarization** — pyannote.audio integration, requires HuggingFace token.
- **Watch mode** — `transcribe-audio batch --watch DIR` for inbox-style processing.
- **Realtime / streaming** — `gpt-4o-transcribe` supports streaming inputs; would require a different audio capture pipeline.
- **Multi-vault routing** — read each vault's `CLAUDE.md`, route notes via LLM judgment.
- **Anthropic Claude backend for summaries** — `--summary-backend anthropic` requires `ANTHROPIC_API_KEY`.
- **Translation** — `--translate-to en` calls Whisper's `task=translate` (currently English-target only) or layers a separate LLM translation step.
- **iPhone Shortcut integration** — auto-process any file dropped in an iCloud folder.
