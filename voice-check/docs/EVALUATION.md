# Evaluation: does the profile actually capture your voice?

`voice-check eval` answers this with a held-out discrimination test plus a
rewrite demo. It reports **aggregate numbers only** — never your text — so it is
safe to run on a private corpus.

## What it proves

A voice profile is only meaningful if it can tell *your* writing apart from
generic-AI prose. The harness measures exactly that:

1. **Held-out split.** Your writing is split into train/test with a seeded,
   deterministic hash split. The profile is built on **train only**, so the test
   text is genuinely unseen.
2. **Discrimination.** Held-out positives (your real writing) and negatives are
   each scored by the checker. Reported:
   - **ROC-AUC** (Mann-Whitney U) — probability a random positive outranks a
     random negative. 1.0 = perfect, 0.5 = chance.
   - **Accuracy** at the best single threshold, the threshold, and the mean gap.
3. **Rewrite demo.** Generic-AI drafts are run through `mechanical_polish`; the
   score rises and AI tells drop.

## Two negative sets

- **Independent generic-AI** (default): negatives come from a contrast corpus
  written without reference to your data (`examples/contrast`, or `--negatives
  <dir>`). Tests whether your writing outranks generic AI prose.
- **Content-matched** (`--content-matched`): negatives are AI-style paraphrases
  of *your own held-out sentences*, produced deterministically by `ai_ify`. Same
  content, different style — so a high AUC here isolates **style/voice** from
  **topic**. Runs entirely in-process; no text leaves your machine.

## Success bar

**ROC-AUC ≥ 0.85** on held-out data. Both modes are expected to clear it for a
corpus with a consistent voice.

## Reproduce

On the shipped synthetic example corpus (no personal data, runs in CI):

```bash
voice-check eval --input examples/sample_corpus --negatives examples/contrast
# ROC-AUC 1.0, accuracy 1.0, large score gap; rewrite demo improves every draft.
```

On your own corpus:

```bash
voice-check eval --input ~/my-writing
voice-check eval --input ~/my-writing --content-matched --report /tmp/eval.md
```

## Honest caveats

- Discrimination is easiest against AI prose (strong tells: em dashes, no
  contractions, corporate words, uniform rhythm). The content-matched mode is the
  harder, more honest test because it controls for topic.
- The deterministic score is the *measurable* core. The `/voice-check` skill adds
  an LLM rewrite on top, grounded in these same signals.
- A spoken-only corpus produces a written target by stripping filler from the
  spoken profile; the profile records `derived_from: "speech"` so this is explicit.
