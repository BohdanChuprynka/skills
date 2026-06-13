---
name: transcribe-audio
description: Transcribe audio files (mp3, m4a, wav, mp4, webm) into clean text via the OpenAI Whisper API, with optional LLM summary and optional Obsidian note export. Supports Ukrainian, Russian, English, and code-switching. Use whenever the user says "/transcribe-audio", "transcribe this file", "transcribe the recording", "transcribe and summarize", "make a note from this audio", "process this voice recording", or provides a path to an audio/video file and asks to convert it to text. Auto-trigger when the user pastes an audio file path or mentions wanting to convert a recording into a transcript or summary.
---

# transcribe-audio

Wrapper around the `transcribe-audio` CLI that runs locally on the user's Mac. The skill's job is to: (a) confirm the audio file the user means, (b) pick smart defaults for language and prompt-priming based on context, (c) run the CLI, (d) report results and offer follow-ups.

## Mental model

The user gives you an audio file. You hand it to the `transcribe-audio` CLI. The CLI handles probe, chunking (if file >24 MB), Whisper API call(s), optional summary, and optional Obsidian note. You handle the **judgment** the CLI cannot: which language to bias toward, which technical vocabulary to prime, whether the user wants a summary, whether the result belongs in Obsidian.

## When to invoke

- Slash command: `/transcribe-audio`
- User says: "transcribe this", "what does this audio say", "make a note from this recording", "convert this to text"
- User pastes a file path ending in `.mp3`, `.m4a`, `.wav`, `.mp4`, `.webm`, `.opus`, `.aac`, `.ogg` and asks for a transcript
- User mentions a recording, voice memo, or call audio that needs processing

## When NOT to invoke

- Live transcription / streaming — this skill is for finished files only
- Speaker diarization (who-said-what) — not implemented in v1
- Re-transcribing an already-good transcript — point them at `transcribe-audio summarize` instead

## Workflow

### 1. Resolve the audio file

The user may give you:
- An absolute path → use it
- A relative path → resolve from CWD
- A file name only → search common locations: `~/Downloads/`, `~/Desktop/`, `~/Documents/`
- A description ("the call I had earlier") → ask which file

Always confirm the file exists before running:

```bash
ls -la "<path>"
```

If multiple candidates match a vague description, list them with timestamps and ask the user to pick.

### 2. Decide language & prompt-priming

**Language flag (`--language`):**
- If the user said the audio is in a specific language → pass `--language uk` / `--language en` / `--language ru`
- If unsure → leave default (`auto` from config)
- If the user mixes languages heavily, pass the dominant language; Whisper handles code-switching fragments inline

**Initial prompt (`--prompt`):**
This is the most under-used lever. The prompt biases Whisper toward correctly transcribing proper nouns and technical vocabulary that appear in it. Build one from conversation context:
- Names mentioned in the surrounding chat
- Technical terms the user has been using (model names, framework names, jargon)
- Domain context ("medical imaging", "knowledge graphs", etc.)

Pass it as a single sentence in the audio's dominant language. Example for a Ukrainian/English tech call:

```
--prompt "Розмова про knowledge graphs, ontology, GraphRAG, Neo4j. Учасники: Mark, Anastasia."
```

Skip the prompt only if you have no context.

### 3. Decide what flags to pass

Run `transcribe-audio --help` once if you're not sure of the current flag surface. Default invocation should be:

```bash
transcribe-audio transcribe "<file>" --language <code> --prompt "<priming>" --formats txt,srt
```

Add `--summary` if:
- User asked for a summary, debrief, key points, or action items
- The audio is >5 min and clearly substantive (meeting, interview, lecture)

Add `--obsidian` if:
- User said "save to Obsidian" / "add to my notes" / "put in my vault"
- This appears to be a meeting/call/dictation that belongs in the user's persona vault per the global CLAUDE.md mission

If unclear → ask once: "Want me to also save to Obsidian and generate a summary?"

### 4. Run the CLI

Use Bash to invoke. The CLI prints progress + paths. Stream the output so the user sees progress live.

For files >30 min the CLI prompts for confirmation. Pass `--no-confirm` only if the user explicitly said "just run it" or pre-approved.

### 5. After the run

The CLI writes:
- `<base>.txt` — clean transcript
- `<base>.srt` — timestamped subtitles
- `<base>.summary.md` (if `--summary`)
- A note in the configured Obsidian vault (if `--obsidian`)

Your job after the run:

1. **Read the transcript** (use `head -100` or full Read if short — but cap it; don't dump 50k tokens of transcript text back into the conversation)
2. **Report:** file paths, duration, detected language, 1-sentence content summary
3. **Offer follow-ups** when relevant:
   - "Want me to extract action items?"
   - "Should I route this to a specific vault page instead of the inbox?"
   - "Want me to translate any sections to English?"

### 6. Smart vault routing (Bohdan-specific, optional)

If `--obsidian` was used, the CLI drops the note in `{vault_path}/inbox/`. For users with the multi-vault setup described in their global CLAUDE.md (gym-sprint, me, projects, learning, setup, personal-notes), you can apply judgment:

1. Read the just-written note
2. Based on content, decide which vault it actually belongs in
3. Move it there with `mv` and ask the user to confirm

For a generic user without that setup, leave it in the configured inbox.

## Errors you may see

- **`OPENAI_API_KEY not set`** → tell the user to add their key to `~/.config/transcribe-audio/.env` (or `export OPENAI_API_KEY=...`), then re-run. A `.env` in the repo/working dir is intentionally NOT read.
- **`ffmpeg not found`** → `brew install ffmpeg` on macOS.
- **`File not found`** → user gave a bad path. Search common locations and ask.
- **`File too large` even after chunking** → unlikely; means chunking failed. Re-run with `--formats txt` and report.
- **Rate-limited by OpenAI** → wait + retry. The CLI doesn't yet auto-retry; surface the error.

## Cost awareness

Whisper API = $0.006/min. A 60-min call costs ~$0.36. The CLI prints the estimate before running. If the user mentions cost concerns, note this — it's cheap for almost any single use case.

## Examples

**Quick transcript:**
```
User: transcribe ~/Downloads/team-sync.m4a
You: [run] transcribe-audio transcribe ~/Downloads/team-sync.m4a --language en
You: [report] ~/transcripts/team-sync.txt — 23 min English meeting, 4 speakers, mostly about Q3 roadmap.
```

**Full pipeline:**
```
User: /transcribe-audio ~/Downloads/mark-call.mp3 — це українська розмова про knowledge graphs
You: [run] transcribe-audio transcribe ~/Downloads/mark-call.mp3 --language uk --prompt "Розмова про knowledge graphs, ontology, Neo4j, GraphRAG" --summary --summary-style brief --obsidian
You: [report] transcript + summary + Obsidian note paths. 1-sentence content recap.
```
