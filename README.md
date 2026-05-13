<div align="center">

<h1>dream-skill</h1>

<p><strong>reconcile your personal wiki against what you actually told claude this week</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/BohdanChuprynka/dream-skill?style=flat" alt="License"></a>
  <a href="https://github.com/BohdanChuprynka/dream-skill/stargazers"><img src="https://img.shields.io/github/stars/BohdanChuprynka/dream-skill?style=flat&color=yellow" alt="Stars"></a>
  <a href="https://github.com/BohdanChuprynka/dream-skill/releases"><img src="https://img.shields.io/github/v/release/BohdanChuprynka/dream-skill?style=flat&include_prereleases" alt="Version"></a>
</p>

<p>
  <a href="#the-problem">Problem</a> &middot;
  <a href="#what-dream-skill-does">What it does</a> &middot;
  <a href="#how-it-works">How</a> &middot;
  <a href="#install">Install</a> &middot;
  <a href="#example-output">Example</a> &middot;
  <a href="#configuration">Config</a> &middot;
  <a href="#cost">Cost</a>
</p>

</div>

---

## The problem

Karpathy keeps pointing out that the missing piece for personal LLMs is a hand-curated knowledge base. He's right. If you keep an Obsidian vault about yourself — roles, projects, training plan, taste, relationships — the model can finally produce output that fits *you* and not the average user.

The catch nobody talks about: that wiki goes stale fast. You curate it once during a productive Saturday, then life happens. Six months later your `roles/current.md` still says you work at a company you left in February. Your `projects/active.md` lists three projects, two of which shipped, one of which you quietly abandoned. The model now reads a confident document about a person who no longer exists, and the personalization gets worse the more it trusts the file.

dream-skill is the fix. Once a week, it reads your recent Claude Code sessions, walks your vault, and produces a structured report of what's gone stale, what's missing, and what contradicts itself. You review the report, accept what's correct, and the vault stays alive.

## What dream-skill does

- Diffs your last N days of Claude Code session transcripts against your vault contents.
- Surfaces three buckets: **auto-apply** (multi-channel agreement, high confidence), **needs confirmation** (single-channel signal, ask the user), **open contradictions** (vault says X, signals say Y).
- Optionally cross-references Notion pages, Gmail subjects, and Calendar events for additional channels.
- Writes a dated markdown report to `<vault>/dream-reports/` for human review.
- Applies accepted proposals with `--apply`. Every edit logged. One command rolls back the entire cycle.
- Runs the reconcile pass under an isolated MCP config so your daily Claude Code session never sees these servers.

## How it works

```
sessions (jsonl)                                  vault (markdown)
       |                                                |
       v                                                v
  preprocess.py                                   load_vault_state.py
       |                                                |
       +------------------+ +---------------------------+
                          | |
                          v v
                   reconcile (claude)  <-- optional MCPs: notion / gmail / calendar
                          |
                          v
                 dream-<date>.md  -->  user review  -->  apply_auto.py --apply
                                                                |
                                                                v
                                                       .apply-log.jsonl
                                                       (apply_undo.sh reverts)
```

Four stages. Two are free local Python. One is a single paid Claude call (~$0.10 on Sonnet 4.6 with cache hits). One is manual review on your terms.

The Python stages do the boring heavy lifting — chunking sessions, filtering to user-biased signal, snapshotting frontmatter — so the paid call gets a clean, compact input and stays cheap.

## Example output

A real report looks roughly like this (names changed):

```markdown
---
date: 2026-05-13
window: 7d
sources: [sessions, notion, calendar]
---

# dream-report 2026-05-13

## auto-apply (>=2 channels)
- **persona/role.md**: title changed from "Engineer at Acme Corp" -> "Senior Engineer at Phoenix Labs"
  evidence:
    - calendar: 1:1 with Phoenix Labs CEO 2026-05-08
    - notion: offer letter page edited 2026-05-09
    - sessions: "starting at Phoenix Monday" (2026-05-10)

- **persona/location.md**: city changed Berlin -> Lisbon
  evidence:
    - calendar: recurring events moved to WET 2026-05-06
    - sessions: "from the new apartment" with Lisbon weather refs

## needs confirmation (1 channel)
- **projects/side-quest.md**: should status flip to completed?
  evidence: session 2026-05-11 ("shipped v1.0, moving on")
  question: confirm completed vs ongoing maintenance phase?

- **persona/reading.md**: add "Working in Public" (Eghbal)?
  evidence: session 2026-05-09, recommended it twice in one conversation
  question: actually reading it or just citing it?

## open contradictions
- **fitness/training.md** says "5x/week running"
  signals: calendar shows 2 runs in the last 14 days
  hypothesis: schedule slipped vs page is stale
  question: which is true right now?

- **persona/diet.md** lists "no caffeine after 2pm"
  signals: 3 sessions mentioned espresso post-4pm this week
  hypothesis: rule abandoned or one-off
  question: still a rule?

## signals not acted on
- session mentioned "considering grad school" (single mention, exploratory)
- calendar shows recurring "therapy" event (intentionally not tracked in vault?)
```

That's it. You read it, mark up the parts you want applied, run `apply_auto.py --apply <report>`, and the proposals are written to the vault with a rollback log.

## Install

```bash
/plugin marketplace add BohdanChuprynka/dream-skill
/plugin install dream-skill@dream-skill-marketplace
```

Then run the setup wizard from the cloned plugin directory:

```bash
./setup.sh
```

The wizard asks for your vault root, your session log path, and any optional MCPs you want enabled. Defaults work for a stock Claude Code + Obsidian setup.

## Quickstart

Zero MCPs, one cycle, ~3 minutes:

```bash
# 1. install per above
# 2. setup
./setup.sh                                # set $DREAM_VAULT_ROOT and friends
# 3. dry run — builds inputs, skips the LLM call
./dream.sh --dry-run
# 4. real cycle — costs ~$0.10
./dream.sh
# 5. read the report
open "$DREAM_VAULT_ROOT/dream-reports/dream-$(date +%F).md"
# 6. apply what you accepted
./scripts/apply_auto.py --apply "$DREAM_VAULT_ROOT/dream-reports/dream-$(date +%F).md"
```

To roll back a cycle:

```bash
./scripts/apply_undo.sh 2026-05-13
```

## What you'll need

- Claude Code CLI (logged in)
- Python 3.11+
- A markdown directory you treat as your personal wiki (Obsidian is the assumed shape, but any folder of markdown files with YAML frontmatter works)
- Node 18+ — only if you want the optional MCP integrations

## Compatibility

dream-skill has only been tested against **Claude Code** (the official CLI). It assumes Claude Code's session log layout (`~/.claude/projects/<encoded-cwd>/*.jsonl`) and depends on Claude Code-specific flags (`--mcp-config`, `--strict-mcp-config`, `--append-system-prompt`, `--output-format json`). Other agent runtimes (Codex, Cursor, Gemini, etc.) are not verified and likely require adaptation. Ports are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Configuration

dream-skill reads three env vars and one TOML file. Everything else is convention:

```bash
export DREAM_VAULT_ROOT="$HOME/Documents/Obsidian"           # required
export DREAM_SESSION_LOG_DIR="$HOME/.claude/projects"        # default
export DREAM_REPORTS_DIR="$DREAM_VAULT_ROOT/dream-reports"   # default
```

Vault categories, signal patterns, and channel weights live in `config/`. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference.

## MCP integrations (optional)

dream-skill works in three tiers. Pick how far you want to go.

**Tier 0** — zero config. Just vault snapshot plus session signals. This is enough to catch most stale-page issues and runs on every machine.

**Tier 1** — add the Filesystem MCP for read-only access to a sandboxed inbox folder (drop screenshots, exported chats, anything markdown-shaped). The reconcile call picks them up as an extra channel.

**Tier 2** — add any combination of Notion, Gmail, and Calendar MCPs. Each is independently optional. More channels means higher-confidence auto-apply proposals and fewer "needs confirmation" entries.

Critical: dream.sh launches Claude with `--mcp-config <skill>/config/mcp-config.json --strict-mcp-config`. Only the dream MCPs load. Your daily Claude Code session is untouched.

Per-server setup walkthroughs (auth, tokens, scopes) live in [docs/MCP-SETUP.md](docs/MCP-SETUP.md).

## Cost

Roughly **$0.10 per cycle on Sonnet 4.6 with prompt caching enabled**. Weekly cadence gives you ~$0.40/month. Daily is overkill for most people and runs ~$3/month.

The dollar figure comes from the prompt staying mostly cache-resident across cycles (vault snapshot changes slowly; system prompt is fixed). First-run cost can be 2-3x higher because the cache is cold. Watch the `.usage-log.jsonl` file for actual per-cycle numbers in your environment.

## Safety

- **Dry-run by default.** `dream.sh` writes the report; nothing touches your vault. `apply_auto.py` writes nothing without `--apply`.
- **Every edit is logged.** Each apply cycle appends to `.apply-log.jsonl` with file path, before-bytes, after-bytes, and timestamp.
- **One-command rollback.** `apply_undo.sh <date>` restores every file the cycle touched, in reverse order.
- **MCP isolation.** The reconcile call uses `--strict-mcp-config`. Tokens you authorize for Notion/Gmail/Calendar live in `config/mcp-config.json` (gitignored, never committed) and load only when dream.sh runs.
- **No autonomous firing.** No cron registered by the installer. You run it. If you want it on a schedule, set up your own cron — that's a deliberate choice, not a default.

## FAQ

**Does this work without an Obsidian vault?**
Yes. Any directory of markdown files with YAML frontmatter works. dream-skill cares about file paths, titles, `status:`, and `updated:`. The Obsidian assumption is convention, not a hard dependency.

**Can I use it without any MCPs?**
Yes. Tier 0 is the default and runs against just your session logs and vault. You'll get fewer multi-channel auto-apply candidates and more "needs confirmation" entries, which is the right tradeoff for new users.

**Why a separate MCP config instead of using my existing one?**
Because cross-pollution is bad. Your daily Claude session probably has its own MCPs (project-specific, work-specific). Loading Notion/Gmail there leaks personal context into work contexts. dream-skill's MCPs only exist for the duration of one reconcile call.

**Will it apply changes I haven't reviewed?**
No. The default `dream.sh` run produces a report and stops. Applying requires running `apply_auto.py --apply` against a specific report file. There is no autonomous write path.

## Contributing

PRs welcome. The repo is small and the surface is intentionally limited. Read [CONTRIBUTING.md](CONTRIBUTING.md) first — it lists which file to edit when you want to change behavior, the local dev loop, and how to test a skill change end-to-end.

## Acknowledgments

- Andrej Karpathy's framing of the "stale personal LLM knowledge base" problem is the reason this exists.
- Anthropic's Claude Code, the plugin manifest format, and the skill spec.
- Obsidian, for being a markdown editor that doesn't try to be a platform.

## License

MIT — see [LICENSE](LICENSE).

---

Built by [Bohdan Chuprynka](https://github.com/BohdanChuprynka).
