---
description: Audit (and optionally rewrite) a draft in your own voice using the offline voice-check CLI and your measured profile. Reports findings by default; rewrites only when asked.
---

Run the `voice-check` CLI to audit the draft the user gives you against their voice profile, then report. Rewrite only if they ask.

## 1. Profile

Default location: `~/.config/voice-check/profile`. If it is missing, tell the user to build one:

```bash
voice-check profile --input <dir-of-their-writing> --out ~/.config/voice-check/profile
```

## 2. Audit

```bash
voice-check check --profile ~/.config/voice-check/profile --draft <file>
# or pasted text:  echo "<draft>" | voice-check check --profile ~/.config/voice-check/profile
# --format json → raw signals;  --rewrite → deterministic baseline rewrite
```

## 3. Report (default)

Give the score out of 100, then each violation with its fix — em dashes, corporate words, AI tells, leftover filler, sentence-length drift, missing contractions — and what already sounds like the user. Do **not** auto-rewrite.

## 4. Rewrite (only when asked)

Fix every hard violation and as many soft ones as possible WITHOUT inventing facts or changing meaning. Preserve the user's rhythm and directness. Use `--rewrite` as a starting baseline, then improve it. End with a 1–2 line rationale.

Everything runs locally. Cite the profile's statistics, never raw corpus lines. The draft is the user's own text and may be quoted.
