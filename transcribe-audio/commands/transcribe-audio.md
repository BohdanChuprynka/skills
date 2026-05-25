---
description: Transcribe an audio file via the OpenAI Whisper API. Optional LLM summary + Obsidian note. Supports en/uk/ru and code-switching.
argument-hint: <audio-file-path> [--summary] [--obsidian]
---

# /transcribe-audio

Transcribe an audio file into clean text using the OpenAI Whisper API. Optionally generate an LLM summary and write a structured Obsidian note.

## Usage

```
/transcribe-audio <path-to-audio>
/transcribe-audio <path-to-audio> --summary
/transcribe-audio <path-to-audio> --summary --obsidian
/transcribe-audio <path-to-audio> --language uk --prompt "tech vocab here"
```

## Arguments

- **`<path-to-audio>`** — file to transcribe. Any format ffmpeg can read.
- **`--summary`** — also generate an LLM summary (default style: brief).
- **`--summary-style <style>`** — `brief` | `detailed` | `action_items` | path to a custom template.
- **`--obsidian`** — write the transcript + summary to a note in the configured Obsidian vault.
- **`--language <code>`** — force language. `auto` (default), `uk`, `en`, `ru`, etc.
- **`--prompt "<text>"`** — initial prompt for Whisper to prime proper-noun / technical vocabulary recognition.
- **`--formats <list>`** — comma-separated output formats: `txt`, `srt`, `vtt`, `json`, `all`. Default `txt,srt`.
- **`--no-confirm`** — skip the cost-confirmation prompt for files >30 min.

## What this command does

1. Probes the audio file (duration, codec, size)
2. Estimates the OpenAI API cost
3. Splits files >24 MB into chunks (Whisper API's per-request size limit)
4. Calls the OpenAI Whisper API for each chunk in parallel
5. Stitches segments back together with corrected timestamps
6. Writes the transcript as `.txt`, `.srt`, etc.
7. (Optional) generates an LLM summary
8. (Optional) writes a structured Obsidian note with frontmatter

Then routes the output intelligently: if the user has a multi-vault Obsidian setup, the skill can move the note from the inbox to the right vault based on content.

## Setup

Before first use:
1. `cd skills/transcribe-audio && ./setup.sh`
2. Add `OPENAI_API_KEY=sk-...` to the `.env` file
3. (Optional) `transcribe-audio init` to set Obsidian vault path

## Examples

**Plain transcript:**
```
/transcribe-audio ~/Downloads/standup.mp3
```

**Ukrainian call with tech vocab + summary + Obsidian note:**
```
/transcribe-audio ~/Downloads/mark-call.mp3 --language uk --prompt "knowledge graphs, ontology, Neo4j" --summary --obsidian
```

**Action items only:**
```
/transcribe-audio ~/Downloads/team-sync.m4a --summary --summary-style action_items
```

When invoking the skill, **read SKILL.md** (skills/transcribe-audio/SKILL.md) for the full decision logic about language detection, prompt priming, vault routing, and follow-up behavior.
