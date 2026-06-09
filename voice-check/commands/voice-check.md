---
description: Audit a draft in your own voice using the offline voice-check CLI and your measured profile. Reports the findings, then immediately delivers the rewritten draft.
---

Run the `voice-check` CLI to audit the draft the user gives you against their voice profile, report the findings, then immediately deliver the rewritten draft in their voice. Do not ask permission before rewriting.

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

## 3. Report

Give the score out of 100, then each violation with its fix — em dashes, corporate words, AI tells, leftover filler, sentence-length drift, missing contractions — and what already sounds like the user.

## 4. Rewrite (always — deliver it without asking)

Then immediately deliver the full rewritten draft. Fix every hard violation and as many soft ones as possible WITHOUT inventing facts or changing meaning. Preserve the user's rhythm and directness. Use `--rewrite` as a starting baseline, then improve it. End with a 1–2 line rationale. The rewritten draft is the last section and the real deliverable. The only things that stop it: out-of-scope input (code/docs), or a fix that would require fabrication — then apply the honest version and flag what to verify.

Everything runs locally. Cite the profile's statistics, never raw corpus lines. The draft is the user's own text and may be quoted.
