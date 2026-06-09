---
name: voice-check
description: Audit and rewrite a draft so it sounds like the user's real writing, not generic AI. Wraps the offline `voice-check` CLI (a measured voice profile + a deterministic 0-100 score). Use whenever the user says "/voice-check", "does this sound like me", "make this sound like me", "voice check this", "de-AI this draft", or asks to audit or rewrite an email, post, message, or essay in their own voice. Reports the findings, then immediately delivers the rewritten draft in the user's voice.
---

# voice-check

Wrapper around the offline `voice-check` CLI. The CLI scores a draft 0–100 against the user's **measured voice profile** and flags concrete signals: em dashes, corporate words, generic-AI tells, leftover spoken filler, sentence-length drift, and missing contractions. Your job is the judgment the CLI cannot do: which findings matter, and a rewrite that fixes them without changing meaning — delivered every time, not on request.

## Mental model

The user has a voice profile built from their own writing (`voice-check profile`). You hand a draft to `voice-check check`; it returns an explainable score plus violations, each with a fix. You interpret that, and on request produce a rewrite that stays in their voice.

## Prerequisites

- The `voice-check` CLI is installed (this skill's `setup.sh` does that).
- A profile exists. Default location: `~/.config/voice-check/profile`. If it is missing, tell the user to build one from a folder of their own writing:
  ```bash
  voice-check profile --input <dir-of-their-writing> --out ~/.config/voice-check/profile
  ```

## Procedure

1. Identify the draft — a file path, pasted text, or the current selection.
2. Run the checker:
   ```bash
   voice-check check --profile ~/.config/voice-check/profile --draft <file>
   # pasted text:  echo "<draft>" | voice-check check --profile ~/.config/voice-check/profile
   # --rewrite → adds a deterministic baseline rewrite;  --format json → raw signals
   ```
3. **Report:** give the score, each violation with its fix, and what already matches the voice.
4. **Then immediately deliver the rewrite — without asking first.** Produce a revised draft that fixes every hard violation and as many soft ones as possible, WITHOUT inventing facts or changing meaning. Preserve the user's rhythm and directness. Use the CLI's `--rewrite` output as a baseline, then improve it with judgment. End with a 1–2 line rationale tied to the findings. The rewritten draft is the real deliverable and comes last. The only things that stop a rewrite: the draft is out of scope (code/docs), or a fix would require fabricating facts — then apply the honest version and flag in one line what to verify.

## When to invoke

- Slash command `/voice-check`, or: "does this sound like me", "make this sound like me", "de-AI this", "voice check this draft".
- Auditing or rewriting an email, post, message, or essay in the user's voice.

## When NOT to invoke

- Writing from scratch with no profile — build a profile first.
- Code comments or technical docs — the style profile does not apply; say "out of scope" and stop.

## Privacy

Everything runs locally. The profile is aggregate statistics only (no raw sentences). Cite the profile's numbers, never raw corpus lines. The draft under review is the user's own text and may be quoted back.

## No shell access?

Read `~/.config/voice-check/profile/voice_profile.md` and apply its rules by hand: em-dash policy, sentence-length band, contraction target, and the filler / corporate / AI-tell lists.
