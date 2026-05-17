<div align="center">

<h1>sync-phone</h1>

<p><strong>iPhone voice dictation, automatically routed into your Obsidian vaults</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/sync-phone?style=flat" alt="License"></a>
  <a href="https://github.com/BohdanChuprynka/sync-phone/stargazers"><img src="https://img.shields.io/github/stars/BohdanChuprynka/sync-phone?style=flat&color=yellow" alt="Stars"></a>
  <a href="https://github.com/BohdanChuprynka/sync-phone/releases"><img src="https://img.shields.io/github/v/release/BohdanChuprynka/sync-phone?style=flat&include_prereleases" alt="Version"></a>
</p>

<p>
  <a href="#the-problem">Problem</a> &middot;
  <a href="#what-sync-phone-does">What it does</a> &middot;
  <a href="#how-it-works">How</a> &middot;
  <a href="#install">Install</a> &middot;
  <a href="#example-output">Example</a> &middot;
  <a href="#configuration">Config</a> &middot;
  <a href="#related">Related</a>
</p>

</div>

---

## The problem

You have a good thought walking to the gym. By the time you're on the treadmill, it's gone. By the time you're back at your laptop, you can't even remember you had it.

The standard fix is "open notes app, type." That works until your thumbs hurt or you're driving or your hands are full of groceries. The actual fix is dictation. Voice-to-text on iOS is good enough now that you can ramble a paragraph at a walk and get something usable back.

But once dictation works, you get the next problem: where does it go? A single Apple Note grows into 200 unsorted bullets nobody re-reads. An Obsidian inbox grows into a 4 MB markdown file that's both append-only and useless. The capture half is solved. The *routing* half is not.

sync-phone is the routing half. You dictate into a single iCloud file from your iPhone. Once you're back at your Mac, one slash command in Claude Code reads the file, summarizes it into clean bullets, drops each bullet into the right Obsidian vault page (creating new pages if needed), archives the cleaned summary, and clears the inbox. Inbox stays close to zero. Your knowledge base stays alive.

## What sync-phone does

- Reads a single capture file (`iphone-raw.md`) that an iPhone Shortcut appends voice dictations to.
- Cleans the raw transcription: strips filler, splits rambling captures into discrete bullets, deduplicates, converts relative dates to absolute.
- Auto-discovers your Obsidian vaults by walking a parent directory and picking up every folder with a `CLAUDE.md`.
- Routes each bullet to the right vault by reading each vault's `CLAUDE.md` schema and `wiki/index.md` catalog.
- Applies bullets autonomously — creates new wiki pages when needed, updates existing ones in place, respects each vault's frontmatter and wikilink conventions.
- Asks once, batched, when a bullet doesn't fit any existing vault — surfaces it rather than dropping silently.
- Archives the cleaned summary (not the raw dictation) to a monthly audit file you can grep later.
- Truncates the capture file so the next dictation lands in a clean inbox.

Everything runs locally in Claude Code. No external services. No data leaves your Mac.

## How it works

```
   iPhone Shortcut                         Mac, in Claude Code
   "Add to Wiki"                           /sync-phone
   (dictate, append)                            |
        |                                       v
        v                                  read iphone-raw.md
   iCloud Drive                                  |
   _obsidian-capture/                            v
   ├── iphone-raw.md   <----------------- summarize into ingest.md
   ├── ingest.md       <-----------------     (per-vault grouping)
   └── archive/                                  |
       └── YYYY-MM.md  <----- append            v
                                           read each vault's
                                           CLAUDE.md + index.md
                                                 |
                                                 v
                                           apply bullets:
                                           - update existing pages
                                           - create new pages
                                           - follow vault conventions
                                                 |
                                                 v
                                           truncate iphone-raw.md
                                           truncate ingest.md
                                           report what was synced
```

The capture side is an iPhone Shortcut. The routing side is a Claude Code skill that reads your vault schemas at runtime — there is no hard-coded vault list. Add a vault, the skill finds it. Move a vault, edit one path.

## Install

### 1. Install the Claude Code plugin

```bash
/plugin marketplace add BohdanChuprynka/sync-phone
/plugin install sync-phone@sync-phone-marketplace
```

That gives you the `sync-phone` skill and the `/sync-phone` slash command in Claude Code.

### 2. Set up the capture directory

Create an iCloud-synced folder that both your iPhone and your Mac can reach:

```bash
mkdir -p ~/Library/Mobile\ Documents/com~apple~CloudDocs/_obsidian-capture/archive
touch ~/Library/Mobile\ Documents/com~apple~CloudDocs/_obsidian-capture/iphone-raw.md
touch ~/Library/Mobile\ Documents/com~apple~CloudDocs/_obsidian-capture/ingest.md
```

The folder name doesn't matter — `_obsidian-capture` is just the default. If you use a different name or location, update the `CAPTURE_DIR` line near the top of `skills/sync-phone/SKILL.md`.

### 3. Build the iPhone Shortcut

Full walkthrough in [docs/SHORTCUT-SETUP.md](docs/SHORTCUT-SETUP.md). Short version:

1. Open Shortcuts.app on iPhone, tap **+**, name it exactly **`Add to Wiki`**.
2. Add actions in order:
   - **Dictate Text** (language: your choice, stop: On Tap)
   - **Get Current Date** (format: `yyyy-MM-dd HH:mm`)
   - **Text** with body: `\n## [Date]\n[Dictated Text]\n`
   - **Append to File**, target: iCloud Drive → `_obsidian-capture` → `iphone-raw.md`
   - **Show Notification** (optional, useful confirmation)
3. Bind it to the iPhone Action Button or Siri ("Hey Siri, add to wiki…").

### 4. Point the skill at your vaults

The skill assumes your Obsidian vaults live under one parent directory and each vault has a `CLAUDE.md` describing its schema. If yours don't yet, see [docs/VAULT-SETUP.md](docs/VAULT-SETUP.md) for the minimum vault shape the skill expects.

Default vault parent: `~/Documents/Obsidian`. If yours is elsewhere, update the `VAULTS_DIR` line near the top of `skills/sync-phone/SKILL.md`.

### 5. Drain the inbox

After you've dictated a few entries:

```
/sync-phone
```

Claude reads, summarizes, routes, archives, clears. See [examples/](examples/) for what a real run looks like.

## Example output

A typical session report after a drain:

```
Synced 3 substantive bullets from iphone-raw.md (4 raw → 1 dropped as misfire)
  gym:    2 files touched
    - wiki/Run 2026-05-16 - 5k Morning.md (created)
    - wiki/log.md (entry added)
  career: 5 files touched
    - wiki/Lenny Podcast - Linear Founder.md (created)
    - wiki/Career Direction.md (Strategy follow-up added)
    - wiki/Active Learning.md (added to Currently Learning)
    - wiki/log.md (entry added)
    - wiki/index.md (Lenny podcast added under Sources)
Archived to: archive/2026-05.md
Cleared: iphone-raw.md, ingest.md
Unrouted: 0
```

See [examples/sample-run.md](examples/sample-run.md) for a full walk-through with the input dictation file, the cleaned `ingest.md`, the resulting vault edits, and the archive entry.

## Configuration

Two paths inside `skills/sync-phone/SKILL.md` are the only knobs:

```
CAPTURE_DIR = ~/Library/Mobile Documents/com~apple~CloudDocs/_obsidian-capture
VAULTS_DIR  = ~/Documents/Obsidian
```

Everything else is convention:

- **Vault discovery** — every folder under `VAULTS_DIR` with a `CLAUDE.md` is a routable vault. No registration step. Add a folder + `CLAUDE.md` and the skill picks it up on the next run.
- **Page conventions** — driven by each vault's `CLAUDE.md`. The skill reads the schema before writing.
- **Archive layout** — `archive/YYYY-MM.md` per month, append-only. Raw dictation is never archived. Only the cleaned summary lands here so the audit stays readable.
- **Ingest format** — see SKILL.md § 3 for the exact `ingest.md` template the skill writes before applying.

If you want stricter approval gates (review each vault's diff before write), edit step 4 of SKILL.md to swap "no per-vault approval" for an `AskUserQuestion` call per vault.

## Why iCloud

iPhone Shortcuts can append to iCloud Drive files with zero configuration. Other targets (Dropbox, S3, local-network shares) require third-party apps, OAuth tokens, or VPNs. iCloud is already on the device, already syncs to the Mac, and the latency is acceptable for the 1–4 voice notes a day this workflow expects.

The Obsidian vaults themselves do **not** need to live in iCloud. The capture folder is the only thing that has to. The skill bridges the two.

## Safety

- **Truncate, never delete.** The iPhone Shortcut needs `iphone-raw.md` to exist as an append target. The skill truncates both `iphone-raw.md` and `ingest.md` to zero bytes instead of deleting them.
- **Archive, then clear.** The skill writes to `archive/YYYY-MM.md` *before* it truncates anything. If the archive write fails, nothing gets cleared.
- **No external network.** Everything runs in your Claude Code session against local files and your Obsidian vaults. No telemetry. No cloud uploads beyond the iCloud sync you already use for the capture file.
- **Defensive on transcription ambiguity.** If a name or number in the dictation is unclear, the skill preserves the ambiguity in the bullet (and notes it) rather than guessing.

## Related

- [dream-skill](https://github.com/BohdanChuprynka/dream-skill) — reconciles your Obsidian vault against recent Claude Code and Codex conversations. Where sync-phone *adds* to the vault, dream-skill *audits* it for staleness.

## Contributing

Issues and PRs welcome. Open an issue first for non-trivial changes so we can agree on direction before you spend the time.

## License

MIT. See [LICENSE](LICENSE).
