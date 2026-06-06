# voice-check

Audit and rewrite drafts so they sound like **your** real writing, not generic
AI. Build a voice profile from your own texts, then score any draft 0–100 against
it and get concrete, fixable findings: em dashes, corporate words, AI tells,
leftover spoken filler, sentence-length drift, missing contractions.

Offline. **Zero third-party dependencies** (Python standard library only). No API
key. Nothing leaves your machine.

Works as a Claude Code + Codex skill (`/voice-check`) and as a standalone
`voice-check` CLI. Part of [BohdanChuprynka/skills](https://github.com/BohdanChuprynka/skills).

## Why

Generic AI prose has tells: em dashes everywhere, no contractions, uniform
sentence length, corporate filler ("leverage", "delve", "moreover"),
over-explained endings. Your real writing has a fingerprint — rhythm, directness,
vocabulary, punctuation habits. voice-check measures that fingerprint from your
own corpus and scores any draft against it, then helps rewrite to match.

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/voice-check
./setup.sh
```

`setup.sh` installs the `voice-check` CLI (via uv/pipx/pip), symlinks the skill +
slash command into Claude Code, copies the skill into Codex, and creates
`~/.config/voice-check/profile`.

## Quickstart

```bash
# 1. Build your profile from a folder of your own writing
voice-check profile --input ~/my-writing --out ~/.config/voice-check/profile

# 2. Audit a draft
voice-check check --profile ~/.config/voice-check/profile --draft draft.md
echo "Let's leverage synergies to delve into this." \
  | voice-check check --profile ~/.config/voice-check/profile

# 3. In Claude Code or Codex
/voice-check
```

Audit by default. `--rewrite` adds a deterministic baseline rewrite; the skill
layers an LLM rewrite on top, grounded in the same signals.

## Input formats

`.txt`, `.md` (optional `kind:` frontmatter), `.jsonl` (a `text` field with
optional `kind`; or Wispr-style `asr_text`/`formatted_text`/`edited_text`),
`.csv` (a `text` column, optional `kind`).

Label spoken vs written with subfolders — `writing/`, `speech/`, `edits/` — so
the profiler keeps your spoken fingerprint separate from your written output
policy. A spoken-only corpus still works: the written target is derived from your
speech with filler stripped. See `examples/sample_corpus/`.

## Proof it captures *your* voice

```bash
voice-check eval --input ~/my-writing                    # vs an independent AI contrast set
voice-check eval --input ~/my-writing --content-matched  # vs AI-styled versions of your own text
```

It splits your writing into train/test, builds a profile on train only, and
checks that held-out real-you text scores higher than generic-AI text — reported
as **ROC-AUC, accuracy, and score gap**, plus a before/after rewrite demo.
Aggregate numbers only; no text leaves your machine. Success bar: ROC-AUC ≥ 0.85.
See [`docs/EVALUATION.md`](docs/EVALUATION.md).

## Privacy

Everything runs locally. The profiler emits **aggregate statistics only** —
counts, rates, length distributions, top n-grams — never raw sentences.
`data/input/`, `data/profiles/`, and `~/.config/voice-check/` stay on your
machine.

## How it works

`corpus` (load + normalize) → `profile` (deterministic stats, spoken-vs-written
split) → `checks` (explainable 0–100 score + rule catalog) → `rewrite`
(mechanical baseline) → `report`. An `eval` harness proves discrimination. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Develop

```bash
pip install -e ".[dev]"
pytest            # 78 tests, standard library only
```

## License

MIT © Bohdan Chuprynka
