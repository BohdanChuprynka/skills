<div align="center">

<h1>clean-wiki</h1>

<p><strong>your obsidian vault is rotting. swipe through the findings, claude does the rest.</strong></p>

<p>
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/skills?style=flat" alt="License"></a>
  <a href="https://github.com/BohdanChuprynka/skills/stargazers"><img src="https://img.shields.io/github/stars/BohdanChuprynka/skills?style=flat&color=yellow" alt="Stars"></a>
  <a href="https://github.com/BohdanChuprynka/skills"><img src="https://img.shields.io/badge/lives_in-skills_monorepo-blue?style=flat" alt="Monorepo"></a>
</p>

<p>
  <a href="#the-problem">Problem</a> &middot;
  <a href="#what-clean-wiki-does">What it does</a> &middot;
  <a href="#how-it-works">How</a> &middot;
  <a href="#screenshots">Screenshots</a> &middot;
  <a href="#prerequisites">Prerequisites</a> &middot;
  <a href="#install">Install</a> &middot;
  <a href="#configuration">Config</a>
</p>

</div>

---

## The problem

Obsidian vaults grow without bound when only writes happen. Every sync, every dream cycle, every late-night note adds more pages. Nothing trims.

After a few months you're staring at:

- pages claiming "I'm currently at X" when X ended weeks ago
- stale `[[wikilinks]]` to renamed pages that nobody noticed
- index entries pointing to files that don't exist anymore
- orphan drafts you forgot about
- "active" projects with `updated:` dates from last quarter

The natural fix is manual cleanup. But manual cleanup of 200 files never happens — too tedious to start, too time-consuming to finish.

You need something that finds the rot and gives you the smallest possible decision per item.

## What clean-wiki does

A monthly cleanup ritual driven by Claude Code. You say `/clean-wiki`, and:

1. **Claude asks which vaults to scan** (in chat, multi-select).
2. **Claude dispatches one sub-agent per vault, in parallel.** Each sub-agent reads every `.md` file in its vault, builds a model of your current truth from your bio / active pages / recently-updated pages, and returns JSON findings: stale facts, contradictions, broken wikilinks, orphans, frontmatter drift, stale active markers.
3. **Findings land in a queue** (`data/cleanup-queue.json`) and a local web UI opens at `http://localhost:5173`.
4. **You swipe through each finding** — approve, reject, defer. Pre-flight batch for mechanical fixes (broken links etc.), per-card swipe for judgment calls (stale facts, orphans).
5. **You click Finish.** The browser tells the server to exit; Claude reads your decisions and applies each approved change via its Edit tool, recording an undo log (`data/undo-log.jsonl`).

Claude does the scanning and applying. You do the deciding. Nothing auto-applies without explicit per-finding approval.

## How it works

```
                                       ┌────────────────────┐
  /clean-wiki                          │  config/           │
  user invokes ─────────────────────►  │  vault-paths.toml  │
                                       └─────────┬──────────┘
                                                 │
                  ┌──────────────────────────────┘
                  │  Claude asks: which vaults?
                  ▼
        ┌──────────────────────┐
        │  Sub-agents (1 per   │     in parallel — each reads
        │  selected vault)     │     its whole vault, returns
        │                      │     JSON findings
        └──────────┬───────────┘
                   │
        ┌──────────▼───────────┐
        │  cleanup-queue.json  │
        └──────────┬───────────┘
                   │
        ┌──────────▼───────────┐
        │  serve.py            │     local Flask review server
        │  http://localhost    │     on port 5173
        │  :5173               │
        └──────────┬───────────┘
                   │
        ┌──────────▼───────────┐
        │  user reviews        │     swipe approve / reject /
        │  in browser          │     defer per finding
        └──────────┬───────────┘
                   │
                   │ Finish → /api/shutdown → server exits
                   ▼
        ┌──────────────────────┐
        │  Claude applies      │     Edit tool per approved
        │  decisions + writes  │     change; undo-log.jsonl
        │  undo-log.jsonl      │     captures before-state
        └──────────────────────┘
```

The only Python in scope is `serve.py` — a thin review server. Scanning and applying live entirely inside Claude Code. The vaults never leave your machine.

## Screenshots

Place screenshots in `docs/screenshots/` and uncomment the references below. Suggested captures:

| File | What to capture |
|--|--|
| `01-preflight.png` | The pre-flight screen with categories collapsed (showing "N mechanical fixes ready") |
| `02-preflight-expanded.png` | One category row expanded, showing the per-file checkboxes |
| `03-card-swipe.png` | A single judgment card mid-review with the diff block visible |
| `04-summary.png` | The summary screen after review with approved/rejected/carried-over counts |

<!--
![Pre-flight screen](docs/screenshots/01-preflight.png)
![Expanded category](docs/screenshots/02-preflight-expanded.png)
![Card swipe](docs/screenshots/03-card-swipe.png)
![Summary](docs/screenshots/04-summary.png)
-->

## Detection signals

Each sub-agent looks for these signals in its assigned vault:

| Signal | Category | What it catches |
|--|--|--|
| `stale_fact` | judgment | Prose claims that contradict the user's current truth or another page in the same vault |
| `broken_wikilink` | auto | `[[X]]` where target X doesn't exist in any configured vault |
| `index_drift` | auto | Dead `[[X]]` entries in `index.md` |
| `frontmatter_drift` | auto | Required frontmatter fields missing |
| `orphan` | judgment | 0 inbound links AND not in index — proposed action: move to archive |
| `stale_superseded` | judgment | `status: superseded` with no replacement link |
| `stale_active` | judgment | `status: active` with no `updated:` in 180+ days |

Auto signals get one-click batch approval (with expandable spot-check before continuing). Judgment signals go through per-card swipe.

## Prerequisites

- **Python 3.11+** (uses stdlib `tomllib`)
- **Flask** (`pip install -r requirements.txt`)
- **Claude Code** — the skill is invoked as `/clean-wiki` from inside Claude Code. Install via [docs.claude.com/claude-code](https://docs.claude.com/claude-code).
- **Obsidian vaults** organized into named subdirectories under a common root

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/clean-wiki/skills/clean-wiki
cp config/vault-paths.example.toml config/vault-paths.toml
# edit config/vault-paths.toml with your real vault paths
pip install -r requirements.txt
```

Symlink so Claude Code can find the skill:

```bash
ln -s "$(pwd)" ~/.claude/skills/clean-wiki
```

Then, inside Claude Code:

```
/clean-wiki
```

The review UI alone can be run without Claude (`bash clean-wiki.sh`), but it only displays — you need Claude to produce the queue and apply the decisions.

## Configuration

`config/vault-paths.toml` (gitignored — template in `vault-paths.example.toml`):

```toml
[[vaults]]
name = "notes"
path = "/Users/you/Documents/Obsidian/notes"
wiki_subdir = "wiki"                # or "" if files are at vault root
index_file  = "wiki/index.md"
archive_dir = "wiki/_archive"
required_frontmatter = ["tags", "created", "updated"]

# repeat per vault...

[ui]
port = 5173
auto_open_browser = true
```

## Safety properties

- **Read-only scan.** Sub-agents read the vaults; they never write.
- **No auto-decisions.** Every applied change requires either per-card swipe approval or batch-approve confirmation in pre-flight.
- **Undo log.** `data/undo-log.jsonl` records the file's prior content per change. `/clean-wiki --undo` in Claude reverses the last batch.
- **Resumable.** Closing the browser mid-review preserves progress. Reopen and continue from the next undecided entry.
- **Carryover.** "Finish later" defers undecided entries to the next month's run.

## Privacy

Vault content never leaves your machine. The `.gitignore` excludes:

- `skills/clean-wiki/data/` — queue, decisions, undo log (all contain vault content)
- `skills/clean-wiki/config/vault-paths.toml` — real absolute paths
- All runtime logs

Only sanitized example config + code + docs get pushed.

If you fork this and push, run `git status --ignored` from the monorepo root before the first push to verify nothing personal slipped through.

## Related

- [dream-skill](../dream-skill) — reconciles your wiki against external sources (Notion, Calendar, Gmail) via LLM proposals
- [sync-phone](../sync-phone) — drains iPhone voice dictation into vaults
- [calendar-plan-skill](../calendar-plan-skill) — drafts tomorrow's calendar from your vault + connected services

`clean-wiki` pairs with these. They write content; this skill trims it.

## License

MIT — see [LICENSE](../LICENSE).
