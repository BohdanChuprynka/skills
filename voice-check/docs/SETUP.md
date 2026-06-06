# Setup

## Requirements

- Python 3.10+
- One of: `uv` (recommended), `pipx`, or `pip`. The tool itself has **no**
  third-party dependencies.

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/voice-check
./setup.sh
```

`setup.sh` is idempotent. It:

1. Installs the `voice-check` CLI (uv → pipx → pip --user, in that order).
2. Creates `~/.config/voice-check/profile`.
3. Symlinks the skill into `~/.claude/skills/voice-check` and the slash command
   into `~/.claude/commands/voice-check.md`.
4. Copies the skill into `~/.codex/skills/voice-check` (if `~/.codex` exists).

Re-run it any time after `git pull` to update.

## Build your profile

Point it at a folder of your own writing (emails, posts, essays, transcripts):

```bash
voice-check profile --input ~/my-writing --out ~/.config/voice-check/profile
```

Label spoken vs written with subfolders for a better profile:

```
~/my-writing/
  writing/   polished writing   → polished_writing
  speech/    transcripts        → raw_speech
  edits/     edited revisions   → edited_revision
```

## Use it

```bash
# CLI
voice-check check --profile ~/.config/voice-check/profile --draft draft.md

# In Claude Code or Codex
/voice-check
```

## Troubleshooting

- **`voice-check: command not found`** — your user scripts dir isn't on PATH. With
  pip `--user`, add `~/.local/bin` (Linux) or the path printed by
  `python3 -m site --user-base` to your shell PATH. With `uv`, ensure
  `~/.local/bin` is on PATH.
- **`No voice_rules.json in ...`** — you haven't built a profile yet, or pointed
  `--profile` at the wrong directory. Run `voice-check profile` first.
- **Skill not appearing in Claude Code** — confirm `~/.claude/skills/voice-check`
  is a symlink to this repo (`ls -l ~/.claude/skills/voice-check`) and restart the
  session.
