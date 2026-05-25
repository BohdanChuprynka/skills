# Extending transcribe-audio

The skill is intentionally small. Most customizations are configuration; the rest are surgical code changes.

## Custom summary styles

The simplest extension. The three built-in styles (`brief`, `detailed`, `action_items`) live in `src/transcribe_audio/templates/summary_styles/`. Each is a plain `.txt` file containing the system prompt the LLM receives.

To add one called `executive`:

```bash
$EDITOR src/transcribe_audio/templates/summary_styles/executive.txt
```

Write the system prompt. Then use it:

```bash
transcribe-audio transcribe call.mp3 --summary --summary-style executive
```

**Alternatively, point at any file path:**

```bash
transcribe-audio transcribe call.mp3 --summary --summary-style ~/my-prompts/strategic.txt
```

This makes per-project or per-domain summary styles trivial without forking the code.

## Custom Obsidian template

The Jinja2 template lives at `src/transcribe_audio/templates/obsidian_note.md.j2`. Edit it to add fields, change the layout, or restructure sections.

Available context variables inside the template:

| Variable | Type | Description |
|---|---|---|
| `title` | str | Filename-derived title |
| `frontmatter` | dict | All frontmatter fields (see below) |
| `transcript` | str | Full transcript text |
| `summary` | str \| None | LLM summary, or None |
| `segments` | list | List of `Segment(start, end, text)` |

Frontmatter dict keys: `created`, `type`, `source`, `duration_seconds`, `language`, `transcribe_model`, `summary_model`, `summary_style`. The `extra_frontmatter` argument to `write_obsidian_note()` can inject more.

## Adding an output format

Steps:

1. Add a method on `TranscriptionResult` in `transcribe.py`:

```python
def to_csv(self) -> str:
    lines = ["start,end,text"]
    for seg in self.segments:
        text = seg.text.replace('"', '""').strip()
        lines.append(f'{seg.start:.3f},{seg.end:.3f},"{text}"')
    return "\n".join(lines)
```

2. Add a branch in `cli.transcribe()` under the `format_set` handling:

```python
if "csv" in format_set:
    p = base.with_suffix(".csv")
    p.write_text(result.to_csv(), encoding="utf-8")
    written.append(p)
```

3. Update the `--formats` help string in the CLI argument.

4. Add a test.

## Plugging in Anthropic Claude for summarization

`summarize.py` currently uses `OpenAI` client. To support Claude:

1. Add `anthropic` to `pyproject.toml` dependencies.
2. Branch on `config.summary_model`:

```python
if config.summary_model.startswith("claude-"):
    from anthropic import Anthropic
    client = Anthropic()  # reads ANTHROPIC_API_KEY from env
    response = client.messages.create(
        model=config.summary_model,
        max_tokens=2000,
        system=system_prompt,
        messages=[{"role": "user", "content": transcript}],
    )
    text = response.content[0].text
else:
    # existing OpenAI branch
```

3. Add `ANTHROPIC_API_KEY` to `.env.example`.
4. Update `config.py` summary_model field to accept both providers.

## Watch mode (batch processing inbox)

Not yet implemented but the design is:

```python
# new file: src/transcribe_audio/watch.py
import time
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

class AudioInboxHandler(FileSystemEventHandler):
    def on_created(self, event):
        if event.is_directory:
            return
        if Path(event.src_path).suffix.lower() in {".mp3", ".m4a", ".wav", ".mp4"}:
            # process via transcribe_file() then move to processed/
            ...
```

Add a `transcribe-audio watch DIR` command to `cli.py`. Use `watchdog` as a dependency.

## Speaker diarization

Whisper does not output speakers. To add who-said-what:

1. Install `pyannote.audio` (requires HuggingFace account + token).
2. Run diarization in parallel with transcription:

```python
from pyannote.audio import Pipeline
pipeline = Pipeline.from_pretrained(
    "pyannote/speaker-diarization-3.1",
    use_auth_token=os.environ["HUGGINGFACE_TOKEN"],
)
diarization = pipeline(audio_path)
# diarization gives (start, end, speaker_label) tuples
```

3. Merge: for each Whisper segment, find the overlapping diarization label by IoU. Attach `speaker` to the `Segment` dataclass.
4. Update the Obsidian template + SRT to render `[SPEAKER_00]` prefixes.

This is a v2 feature because the HF download is ~1 GB and dependency footprint is large.

## Smart multi-vault routing (skill-side, not CLI)

For users with the multi-vault Obsidian setup described in the global CLAUDE.md, the **skill** (not the CLI) can route notes intelligently:

1. After CLI writes a note to `inbox/`, the skill reads it.
2. Reads each vault's `CLAUDE.md` to understand its scope.
3. Asks Claude: "Which vault does this content belong in?"
4. Moves the file with `mv` and updates frontmatter if needed.

This logic lives in `skills/transcribe-audio/SKILL.md` and stays out of the Python core so the CLI remains universally usable.

## iPhone Shortcut auto-pipeline

Pair this skill with an iPhone Shortcut that uploads recorded audio to iCloud Drive at:

```
~/Library/Mobile Documents/com~apple~CloudDocs/audio-inbox/
```

Then set up a launchd job (similar to `sync-phone`'s) that runs `transcribe-audio batch <inbox-dir>` every N minutes. Or use `watch` mode (see above).

## Hooks / post-processing

For now, post-processing is the user's job after the CLI writes outputs. If you need this in code, add a `--post-hook PATH` flag that runs an arbitrary script after each successful transcription:

```python
if args.post_hook:
    subprocess.run([args.post_hook, str(txt_path), str(json_path)], check=False)
```

Keep the contract simple: hook receives output file paths as positional args. Hook's exit code is ignored.
