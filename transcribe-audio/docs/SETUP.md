# Setup walkthrough

A fully detailed install path. The [README quick start](../README.md#install) covers most cases; this doc handles the edges.

## 1. System dependencies

You need **ffmpeg** and **uv**. Both are one-line installs.

### macOS

```bash
# ffmpeg
brew install ffmpeg

# uv (Astral's modern Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install ffmpeg

# uv
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Windows

PowerShell:

```powershell
# ffmpeg
choco install ffmpeg
# or via winget:
winget install Gyan.FFmpeg

# uv
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

Note: Windows is not the primary support target for this skill. macOS and Linux are tested.

## 2. Clone the monorepo

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/transcribe-audio
```

If you only want this one skill, sparse-checkout works:

```bash
git clone --filter=blob:none --no-checkout https://github.com/BohdanChuprynka/skills
cd skills
git sparse-checkout init --cone
git sparse-checkout set transcribe-audio
git checkout main
cd transcribe-audio
```

## 3. Run the installer

```bash
./setup.sh
```

The script:

1. Checks `ffmpeg`, `uv`, `python3` are present
2. Copies `.env.example` → `.env` (if `.env` doesn't already exist)
3. Installs the `transcribe-audio` CLI via `uv tool install`
4. Symlinks the Claude Code skill into `~/.claude/skills/transcribe-audio`
5. Symlinks the slash command into `~/.claude/commands/transcribe-audio.md`
6. Offers to run `transcribe-audio init` for interactive defaults

The script is idempotent — safe to re-run after `git pull`.

## 4. Add your OpenAI API key

`setup.sh` creates two `.env` files for you:

- **`~/.config/transcribe-audio/.env`** — the canonical one. The installed CLI looks here first, regardless of which directory you run from. Permissions are set to `600` (only you can read it).
- **`./.env`** in the repo — convenience copy for in-repo development.

Edit the canonical one:

```bash
$EDITOR ~/.config/transcribe-audio/.env
```

Set:

```env
OPENAI_API_KEY=sk-proj-...
```

Get a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys). You'll need a small balance funded (~$5 covers hundreds of hours of transcription).

## 5. (Optional) Set Obsidian vault path

If you want `--obsidian` to work, the tool needs to know where your vault lives. Two ways:

**A. Via `.env`** (recommended if your Obsidian setup is straightforward):

```env
OBSIDIAN_VAULT_PATH=/Users/yourname/Documents/Obsidian/personal
```

**B. Via the init wizard:**

```bash
transcribe-audio init
```

The wizard asks for vault path + inbox subdirectory + filename pattern and writes to `~/.config/transcribe-audio/config.yaml`.

## 6. Verify

```bash
transcribe-audio --version
transcribe-audio config show
```

Expected output: version number; config yaml contents (if init was run).

Then test on a real file:

```bash
transcribe-audio transcribe ~/path/to/short-test.mp3
```

You should see a cost estimate, then a progress spinner, then output paths.

## 7. Claude Code integration

After `setup.sh`, restart Claude Code (or run `/reload`) so it picks up the new skill and slash command. Verify:

```
/transcribe-audio --help
```

The skill is now triggerable by `/transcribe-audio` or natural-language phrases like "transcribe this audio."

## Common issues

### `OPENAI_API_KEY not set`

Either `.env` doesn't exist, or the key inside it is still `sk-replace-me`. Edit and try again.

### `ffmpeg not found`

Reinstall ffmpeg and ensure it's on your `$PATH`:

```bash
which ffmpeg
ffmpeg -version
```

### `transcribe-audio: command not found`

`uv tool install` failed silently, or `~/.local/bin` isn't on your `$PATH`. Add this to your shell rc:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then reload your shell.

### Claude Code doesn't see the slash command

```bash
ls -la ~/.claude/commands/transcribe-audio.md
ls -la ~/.claude/skills/transcribe-audio
```

Both should be symlinks pointing into the repo. If missing, re-run `setup.sh`.

### `Unauthorized` from OpenAI

Your API key is invalid, expired, or has no balance. Check the OpenAI dashboard.

### File over 25 MB still fails

`chunk_size_mb` in config defaults to 24. If your input has unusual codec headers or metadata, try forcing a normalization first:

```bash
ffmpeg -i input.weird -ac 1 -ar 16000 -b:a 64k normalized.mp3
transcribe-audio transcribe normalized.mp3
```

## Uninstall

```bash
uv tool uninstall transcribe-audio
rm ~/.claude/skills/transcribe-audio
rm ~/.claude/commands/transcribe-audio.md
rm -rf ~/.config/transcribe-audio
```

Then `rm -rf` the cloned repo directory.
