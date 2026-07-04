<div align="center">

<h1>clean-wiki</h1>

<p><strong>your obsidian vault is rotting. swipe through the findings, the agent does the rest.</strong></p>

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

A monthly cleanup ritual driven by Claude Code or Codex. You invoke the skill, and:

1. **The agent asks which vaults to scan** (in chat).
2. **The agent dispatches one subagent per vault when available.** Each scan reads every `.md` file in its vault, builds a model of your current truth from your bio / active pages / recently-updated pages, and returns JSON findings: stale facts, contradictions, broken wikilinks, index drift, orphans, frontmatter drift, stale active markers.
3. **Findings land in a queue** (`data/cleanup-queue.json`) and a local web UI opens at `http://localhost:5173`.
4. **You swipe through each finding** — approve, reject, defer. Pre-flight batch for mechanical fixes (broken links etc.), per-card swipe for judgment calls (stale facts, orphans).
5. **You click Finish.** The browser tells the server to exit; the agent reads your decisions and applies each approved change, recording an undo log (`data/undo-log.jsonl`) and writing a dated run report.

The agent does the scanning and applying. You do the deciding. Nothing auto-applies without explicit per-finding approval.

## How it works

```
                                       ┌────────────────────┐
  /clean-wiki or $clean-wiki            │  config/           │
  user invokes ─────────────────────►  │  vault-paths.toml  │
                                       └─────────┬──────────┘
                                                 │
                  ┌──────────────────────────────┘
                  │  agent asks: which vaults?
                  ▼
        ┌──────────────────────┐
        │  Subagents when      │     in parallel when available;
        │  available           │     each reads its vault and
        │                      │     returns JSON findings
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
        │  agent applies       │     file edit per approved
        │  decisions + writes  │     change; undo-log.jsonl
        │  undo-log.jsonl      │     captures before-state;
        │  + clean report      │     clean-reports/YYYY-MM-DD-HHMMSS.md
        └──────────────────────┘
```

The Python runtime helpers are intentionally small: `serve.py` runs the local review server, and `scripts/write_report.py` renders the per-run Markdown report. Scanning and applying live in the active Claude Code or Codex agent.

Each completed apply batch also gets a dream-style report via `scripts/write_report.py`:

- `clean-reports/YYYY-MM-DD-HHMMSS.md` — full summary, applied changes, manual leftovers, no-ops, rejects, defers, failures
- `clean-reports/index.md` — one-line per run index

Set top-level `reports_dir` in `config/vault-paths.toml` to override the location. If omitted, reports default to `clean-reports/` beside the configured vault roots.

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

Each scan looks for these signals in its assigned vault:

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
- **Flask** (installed by `./setup.sh` into the skill venv)
- **Claude Code or Codex** — Claude users invoke `/clean-wiki`; Codex users invoke `$clean-wiki` or select the skill.
- **Obsidian vaults** organized into named subdirectories under a common root

## Install

Recommended:

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/clean-wiki
./setup.sh
```

`setup.sh` is idempotent. It:

- creates `skills/clean-wiki/.venv` and installs Flask there;
- creates `skills/clean-wiki/config/vault-paths.toml` if missing;
- symlinks the skill into `~/.claude/skills/clean-wiki` when Claude Code is installed;
- copies a sanitized skill into `~/.codex/skills/clean-wiki` for Codex local use;
- creates a Codex-local config and venv at `~/.codex/skills/clean-wiki`.

Edit `skills/clean-wiki/config/vault-paths.toml` before first use if it still contains `/ABSOLUTE/PATH/` placeholders.

### Claude Code

```
/clean-wiki
```

### Codex

You must restart Codex after setup because Codex scans skills at startup. Then ask:

```
Use $clean-wiki to audit my vaults.
```

The review UI alone can be run without an agent by launching the installed or repo-local `clean-wiki.sh`, but it only displays the current queue. You need Claude Code or Codex to produce the queue and apply approved decisions.

## Configuration

`config/vault-paths.toml` (gitignored — template in `vault-paths.example.toml`):

```toml
# optional; defaults to clean-reports/ beside the configured vault roots
reports_dir = "/Users/you/Documents/Obsidian/clean-reports"

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

- **Read-only scan.** The scan phase reads the vaults; it never writes.
- **No auto-decisions.** Every applied change requires either per-card swipe approval or batch-approve confirmation in pre-flight.
- **Undo log.** `data/undo-log.jsonl` records the file's prior content per change. `/clean-wiki --undo` in Claude Code or `Use $clean-wiki --undo` in Codex reverses the last batch.
- **Per-run reports.** Every completed apply batch writes a local Markdown report under `clean-reports/` or configured `reports_dir`.
- **Resumable.** Closing the browser mid-review preserves progress. Reopen and continue from the next undecided entry.
- **Carryover.** "Finish later" defers undecided entries to the next month's run.

## Privacy

Runtime files, config, queues, decisions, undo logs, and the review UI stay local. The active Claude Code or Codex model provider may receive vault text in model context while scanning, because the agent has to read the vault to classify cleanup findings. Do not run this skill on vaults that should not be read by your active agent provider.

The `.gitignore` excludes:

- `skills/clean-wiki/data/` — queue, decisions, undo log (all contain vault content)
- `skills/clean-wiki/config/vault-paths.toml` — real absolute paths
- `skills/clean-wiki/.venv/` — local Python environment
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
