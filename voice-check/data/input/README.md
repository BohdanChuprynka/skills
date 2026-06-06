# data/input — your writing goes here (local only)

This folder is for building a profile from inside the repo during development.
For normal use, build your profile to the canonical location instead:

```bash
voice-check profile --input <dir-of-your-writing> --out ~/.config/voice-check/profile
```

Everything under `data/input/` (except this README) is git-ignored.

## Supported formats

`.txt`, `.md` (optional `kind:` frontmatter), `.jsonl` (a `text` field, optional
`kind`; or Wispr-style `asr_text`/`formatted_text`/`edited_text`), `.csv` (a
`text` column, optional `kind`).

## Labeling kind (optional)

Use subfolders to separate spoken from written: `writing/` (polished_writing),
`speech/` (raw_speech), `edits/` (edited_revision). The profiler keeps your
spoken fingerprint separate from your written output policy. See
`examples/sample_corpus/` for a worked example.
