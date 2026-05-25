<div align="center">

<h1>transcribe-audio</h1>

<p><strong>Audio file → clean transcript → optional summary → optional Obsidian note. OpenAI Whisper backend.</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/skills?style=flat" alt="License"></a>
  <a href="https://github.com/BohdanChuprynka/skills/stargazers"><img src="https://img.shields.io/github/stars/BohdanChuprynka/skills?style=flat&color=yellow" alt="Stars"></a>
  <img src="https://img.shields.io/badge/python-3.11+-blue.svg?style=flat" alt="Python 3.11+">
  <img src="https://img.shields.io/badge/whisper-API-green.svg?style=flat" alt="OpenAI Whisper API">
</p>

<p>
  <a href="#the-problem">Problem</a> &middot;
  <a href="#what-it-does">What it does</a> &middot;
  <a href="#how-it-works">How</a> &middot;
  <a href="#prerequisites">Prerequisites</a> &middot;
  <a href="#install">Install</a> &middot;
  <a href="#usage">Usage</a> &middot;
  <a href="#configuration">Config</a> &middot;
  <a href="#claude-code-skill">Claude Code skill</a>
</p>

</div>

---

## The problem

You finish a 60-minute call. The conversation mattered. The notes you took during it are sparse, and your memory is already fading. Every transcription tool you've tried is one of:

- A SaaS subscription that owns your data
- A local model that needs 4 GB of disk and 30 minutes of compute per hour of audio
- A free tool with Ukrainian / Russian transcription quality that's barely usable

The cheap, fast, multilingual fix that already exists is the OpenAI Whisper API. $0.006 per minute. Sub-30-second turnaround for a typical call. Strong on English, Ukrainian, Russian, and dozens of other languages — and handles code-switching naturally.

The OpenAI API has just one usability cliff: a hard 25 MB per-request limit. That kills it for any file longer than ~40 minutes at standard quality. **`transcribe-audio` is the missing wrapper:** auto-chunking, parallel uploads, segment-stitching, optional summarization, and optional Obsidian export — all in a single command.

## What it does

- Transcribes any audio (or audio-from-video) file via the OpenAI Whisper API.
- Auto-chunks files larger than 24 MB into mono 16 kHz MP3 segments. Stitches results back into one transcript with correct timestamps.
- Bias the recognizer with a custom **initial prompt** for proper nouns and technical vocabulary — the single highest-leverage knob in Whisper, often skipped by other tools.
- Optional LLM summary in three built-in styles (`brief`, `detailed`, `action_items`) or any custom template file.
- Optional Obsidian export with rich frontmatter, configurable subdirectory and filename pattern.
- Cost estimate printed before every run. Files over 30 minutes ask for confirmation.
- Ships as both a standalone CLI (`transcribe-audio ...`) and a Claude Code skill (`/transcribe-audio`).

## How it works

```
                                                                 [optional]
                                                              ┌───────────────┐
                                                              │  LLM summary  │
                                                              │  (GPT-4o-mini)│
                                                              └──────┬────────┘
                                                                     ▼
   ┌──────────┐     ┌─────────────┐     ┌──────────────────┐    ┌──────────────────┐
   │ Any      │────▶│  ffmpeg     │────▶│  OpenAI Whisper  │───▶│  .txt .srt .vtt  │
   │ audio    │     │  probe +    │     │  API (chunked    │    │  .json + summary │
   │ file     │     │  chunk      │     │  if >24 MB)      │    │  + Obsidian note │
   └──────────┘     └─────────────┘     └──────────────────┘    └──────────────────┘
```

For files ≤24 MB: one API call, one round-trip.

For larger files: `ffmpeg -f segment` slices into time-based chunks, mono 16 kHz @ 64 kbps MP3 (≈ 50 min per chunk under the limit). Up to three chunks transcribe in parallel. Segment timestamps are offset-corrected and merged into one transcript.

## Prerequisites

- **Python 3.11+**
- **ffmpeg** — `brew install ffmpeg` (macOS), `sudo apt install ffmpeg` (Ubuntu)
- **uv** — `curl -LsSf https://astral.sh/uv/install.sh | sh`
- **OpenAI API key** — get one at [platform.openai.com/api-keys](https://platform.openai.com/api-keys)

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/transcribe-audio
./setup.sh
```

`setup.sh`:
1. Checks ffmpeg, uv, python
2. Copies `.env.example` → `.env`
3. Installs the `transcribe-audio` CLI globally via `uv tool install`
4. Symlinks the Claude Code skill + slash command into `~/.claude/`
5. Optionally runs `transcribe-audio init` (interactive wizard for defaults)

Edit `.env` and set `OPENAI_API_KEY=sk-...` before first run.

## Usage

**Basic — transcript only:**

```bash
transcribe-audio transcribe ~/Downloads/call.mp3
```

**Multilingual with technical vocabulary priming:**

```bash
transcribe-audio transcribe ~/Downloads/call.mp3 \
  --language uk \
  --prompt "Розмова про knowledge graphs, ontology, Neo4j, GraphRAG. Учасники: Mark, Anastasia."
```

**Transcript + summary + Obsidian note:**

```bash
transcribe-audio transcribe ~/Downloads/standup.m4a --summary --obsidian
```

**Action items only:**

```bash
transcribe-audio transcribe ~/Downloads/team-sync.mp3 \
  --summary --summary-style action_items
```

**Summarize an existing transcript:**

```bash
transcribe-audio summarize ~/transcripts/call.txt --style detailed
```

**Inspect or change config:**

```bash
transcribe-audio config show
transcribe-audio init      # rerun the wizard
```

All commands accept `--help` for full flag listings.

## Configuration

Three layers, in order of precedence (later wins):

1. **`~/.config/transcribe-audio/config.yaml`** — your defaults (written by `transcribe-audio init`)
2. **`.env`** in the repo — secrets only (`OPENAI_API_KEY`, optional `OBSIDIAN_VAULT_PATH`)
3. **CLI flags** — per-call overrides

Example `config.yaml`:

```yaml
transcribe_model: whisper-1
summary_model: gpt-4o-mini
default_language: auto
default_summary_style: brief
vault_path: /Users/me/Documents/Obsidian/personal
obsidian_inbox_subdir: inbox
obsidian_filename_pattern: "{date}-{slug}"
default_output_dir: /Users/me/transcripts
chunk_size_mb: 24
max_concurrent_chunks: 3
confirm_above_minutes: 30
```

## Cost

Whisper-1 = $0.006 per minute. Real-world examples:

- 10 min standup → $0.06
- 60 min call → $0.36
- 90 min interview → $0.54

GPT-4o-mini summary on a 60-min transcript costs roughly another $0.01-0.03 depending on transcript length.

## Claude Code skill

Once `setup.sh` runs, the skill is wired into your Claude Code install:

```
/transcribe-audio ~/Downloads/call.mp3
/transcribe-audio ~/Downloads/call.mp3 --summary --obsidian
```

The skill picks language and prompt-priming based on conversation context, runs the CLI, reads the output, and offers smart follow-ups. See `skills/transcribe-audio/SKILL.md` for the full decision logic.

## Tests

```bash
uv run --extra dev pytest
```

Tests stub OpenAI HTTP calls so they don't hit the real API. Audio chunking tests use a small fixture file.

## Related skills in this monorepo

- [`sync-phone`](../sync-phone) — drain iPhone voice dictation into Obsidian
- [`calendar-plan-skill`](../calendar-plan-skill) — daily calendar planner
- [`dream-skill`](../dream-skill) — vault reconciliation
- [`clean-wiki`](../clean-wiki) — vault cleanup with swipe-approve UI

## License

MIT — see [LICENSE](LICENSE).
