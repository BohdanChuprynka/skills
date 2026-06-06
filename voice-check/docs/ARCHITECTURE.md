# Architecture

A linear, deterministic pipeline. Standard library only.

```
data/input/  --corpus--> records  --profile--> profile artifacts
                                                      |
draft  --checks/rewrite--> audit result <-------------+
                                                      |
held-out data  --eval--> ROC-AUC + rewrite demo  <----+
```

## Modules (`src/voice_check/`)

| Module | Responsibility |
|---|---|
| `text.py` | Tokenizers: sentence split (guards decimals/abbreviations), word tokens, n-grams, contraction + punctuation counting, phrase counting. Pure functions. |
| `lexicons.py` | Default phrase lists: filler, hedges, corporate, AI tells, inflated claims; corporate→plain and expanded→contraction maps; stopwords. Conservative for anything the rewriter removes. |
| `corpus.py` | Load `.txt/.md/.jsonl/.csv` into `Record(id, source_path, text, kind, created_at, metadata)`. Kind detection: explicit field → frontmatter → subfolder → filename suffix → `unknown`. A Wispr-style jsonl row explodes into raw/polished/edited records sharing a `row_id`. |
| `profile.py` | Deterministic statistics + artifacts. The **modeling split** below. Emits `profile_stats.json`, `voice_rules.json`, `voice_profile.md`. |
| `checks.py` | `check_draft(text, rules)` → explainable audit. Rule catalog + transparent score. |
| `rewrite.py` | `mechanical_polish(text, rules)` — safe, deterministic, idempotent baseline rewrite. |
| `report.py` | Render audit / profile to text / markdown / json. |
| `eval.py` | `roc_auc`, `accuracy_at_best_threshold`, `deterministic_split`, `ai_ify` (content-matched negatives), and `evaluate()`. |
| `skill_template.py` | Render a personalized `SKILL.md` from a profile. |
| `cli.py` | The `voice-check` console entry: `profile` / `check` / `build-skill` / `eval`. |

## Data model

A profile has `overall`, `by_kind`, `written_target`, `spoken_fingerprint`, and
an `asr_formatted_delta`. `voice_rules.json` is the enforceable subset the
checker reads: filler/corporate/AI-tell lists, em-dash policy, sentence-length
band, contraction target, opener/vocab anchors, and `score_weights`.

## Modeling split (the core idea)

Speech is **evidence**, not output style. The profiler separates:

- **Spoken fingerprint** (from raw speech): rhythm, vocabulary, directness, verbs.
  Preserved.
- **Written output policy**: filler stripped, disfluencies removed, punctuation
  per the written samples.

If the corpus has enough polished/edited text, the written target is profiled
from it directly. Otherwise it is derived from speech with the filler
expectation forced to zero and `derived_from: "speech"` recorded.

## Scoring

`score = 100 − Σ penalties`, clamped to 0–100. A hard violation (e.g. an em dash
when the profile bans them) caps the score at 60. Each penalty is attributable to
a named rule, returned in `score_breakdown`. The discrimination eval validates
that this score separates real-user writing from generic-AI text.
