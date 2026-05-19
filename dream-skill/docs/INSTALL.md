# Installing dream-skill

Two install methods. Pick one. After install, run the setup wizard, then a first
`--dry-run` cycle to confirm everything is wired correctly.

---

## Prerequisites

| Requirement | Why | Required? |
|---|---|---|
| [Claude Code CLI](https://docs.claude.com/claude-code) | Runs the reconcile pass; provides `claude` on `$PATH` | Required |
| Local Codex CLI JSONLs | Optional second conversation source at `~/.codex/sessions` | Optional |
| Python 3.11+ | `scripts/load_vault_state.py` uses `tomllib` (stdlib in 3.11+) | Required |
| An Obsidian vault, or any directory of markdown files | The thing we reconcile against | Required |
| Node 18+ (`node`, `npx`) | Only needed if you wire up Tier 1+ MCP integrations (Filesystem / Notion / Calendar / Gmail) | Optional |
| `gh` CLI | Convenience for sharing reports / opening issues | Optional |

Verify the basics:

```bash
claude --help >/dev/null && echo "claude OK"
python3 -c 'import sys, tomllib; print(sys.version)'  # must be 3.11+
node --version    # only if you want MCPs
```

---

## Method A — Claude Code plugin marketplace (recommended)

```bash
/plugin marketplace add BohdanChuprynka/dream-skill
/plugin install dream-skill@dream-skill-marketplace
```

The plugin lands in your Claude Code skills directory. From there, run the
one-time setup wizard:

```bash
cd ~/.claude/skills/dream-skill
./setup.sh
```

The wizard will:

1. Confirm your vault root path (or create a starter layout).
2. Create `config/vault-paths.toml` from the example template.
3. Optionally walk you through wiring any of the four MCPs (see
   [`MCP-SETUP.md`](MCP-SETUP.md)). Skip this and you get Tier 0 — fully working,
   no external dependencies.

---

## Method B — Manual clone

For developers, hackers, or anyone who wants to inspect the code first.

```bash
git clone https://github.com/BohdanChuprynka/dream-skill.git ~/dream-skill
ln -s ~/dream-skill/skills/dream-skill ~/.claude/skills/dream-skill
cd ~/.claude/skills/dream-skill
./setup.sh
```

Symlink so Claude Code discovers the skill in its standard skills directory.
The repo lives wherever you cloned it; only the link is in `~/.claude/skills`.

To update later:

```bash
cd ~/dream-skill && git pull
```

---

## Verifying the install

The repo ships a doctor script that checks every prerequisite:

```bash
cd ~/.claude/skills/dream-skill
./doctor.sh
```

Expected output looks roughly like:

```
[ok]   claude CLI on PATH
[ok]   python3 3.11.7
[ok]   vault root readable: ~/Documents/Obsidian
[ok]   config/vault-paths.toml present
[warn] config/mcp-config.json absent (Tier 0 mode)
[ok]   write access to dream-reports output dir
[ok]   codex conversations: ~/.codex/sessions
```

A `[warn]` for missing MCP config is fine — that just means you'll run in Tier 0
(no external integrations). Any `[fail]` line points to something to fix.

---

## First run (Tier 0, free)

Always do a dry run first. No LLM call, no MCPs, no cost — just confirms the
preprocess and vault-snapshot stages produce sensible inputs.

```bash
./dream.sh --dry-run --no-mcp
```

This writes preview inputs to `/tmp/dream-sessions-<date>.md` and
`/tmp/dream-vault-<date>.md`. Open them, sanity-check that:

- Conversation signals show actual recent Claude/Codex snippets (not empty).
- Vault snapshot lists your pages with `updated:` dates.

If both look right, run a live cycle:

```bash
./dream.sh --no-mcp
```

Report lands at `<vault-root>/dream-reports/dream-<YYYY-MM-DD>.md`. Open it,
read through the proposals. That's the loop.

---

## Adding MCP integrations (Tier 1 and up)

Optional. Skip if Tier 0 already gives you what you need.

See [`MCP-SETUP.md`](MCP-SETUP.md) for the full walkthrough. Quickest path:

```bash
./setup.sh --mcp
```

The wizard will prompt you for each MCP and write `config/mcp-config.json`.

---

## Scheduling with cron

Once you've validated a few cycles by hand, schedule it weekly. Sunday 22:30 is
a reasonable default — captures the week, ready for Monday-morning review.

Crontab line:

```cron
30 22 * * 0 /bin/bash -lc 'PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ~/.claude/skills/dream-skill/dream.sh >> ~/.claude/skills/dream-skill/dream.log 2>&1'
```

Three gotchas to know about:

1. **PATH for `npx`.** Cron runs with a minimal PATH. If you use any MCP
   (Tier 1+), `npx` must be findable. The `/usr/local/bin` and
   `/opt/homebrew/bin` prefixes cover the common Node install locations on
   macOS. Linux: add wherever `which npx` reports.
2. **Login shell.** The `-lc` flag asks bash to source profile files so any
   `nvm`-installed Node is loaded. If you don't use `nvm`, you can drop `-l`.
3. **Logs.** The redirect appends stdout+stderr to a log file. Inspect it after
   the first scheduled run to confirm the cycle actually fired.

If you'd rather use launchd (macOS) or systemd timers (Linux), the principle is
the same: explicit PATH, log output, weekly cadence.

---

## Uninstalling

Plugin install:

```bash
/plugin uninstall dream-skill
```

Manual clone:

```bash
rm ~/.claude/skills/dream-skill        # remove the symlink
rm -rf ~/dream-skill                   # remove the repo
```

Reports under `<vault-root>/dream-reports/` are not touched — they live in your
vault, not the skill directory. Delete them yourself if you want a clean break.

If you set up MCPs and want to fully tear those down too, see the "Token
revocation" section in [`MCP-SETUP.md`](MCP-SETUP.md) before removing the skill
directory — revoke the integration tokens at the source services first.
