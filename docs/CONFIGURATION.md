# Configuration Reference

Every knob you can turn. Settings are resolved in order:

1. **CLI flags** to `dream.sh`
2. **Environment variables** (`DREAM_*` prefix)
3. **Config files** (`config/vault-paths.toml`, `config/signal-patterns.toml`,
   `config/mcp-config.json`)
4. **Built-in defaults**

Anything in (1) overrides (2), (2) overrides (3), and so on.

---

## CLI flags

All flags are optional. `dream.sh` runs with sensible defaults.

| Flag | Type | Default | Description |
|---|---|---|---|
| `--since <window>` | string | `7d` | How far back to scan Claude Code sessions. Examples: `7d`, `14d`, `30d`, `24h`. |
| `--dry-run` | boolean | off | Build inputs (preprocess + vault snapshot) but skip the LLM call. Inputs written to `/tmp/dream-sessions-<date>.md` and `/tmp/dream-vault-<date>.md`. Free; useful for debugging. |
| `--no-mcp` | boolean | off | Force Tier 0 mode for this run — ignore `config/mcp-config.json` entirely. Useful when an MCP is misbehaving. |
| `--model <id>` | string | `claude-sonnet-4-6` | Override the reconciliation model. Example: `claude-opus-4-7` (more expensive). |
| `--output-dir <path>` | path | `<vault-root>/dream-reports` | Override the report destination directory. |
| `--vault-root <path>` | path | from `vault-paths.toml` | Override the vault root for this run. |
| `--sessions-root <path>` | path | `~/.claude/projects` | Where to find Claude Code session JSONLs. Rarely overridden. |
| `--index-file <path>` | path | auto-discover | (apply_auto.py only) Vault index file to update with applied edits. By default, dream-skill looks for `<vault-root>/<subdir>/wiki/index.md` adjacent to each updated page and appends a list entry if the page is not already linked there. Use this flag to point at a single index file when your vault uses a non-standard layout. |
| `--no-index-update` | boolean | off | (apply_auto.py only) Disable vault index updates entirely. |
| `--verbose` | boolean | off | Surface internal logging (preprocess filter decisions, vault snapshot stats). |
| `--help`, `-h` | | | Print usage and exit. |

---

## Environment variables

All are optional. Useful when running under cron, CI, or any context where
shell args are awkward.

| Variable | Type | Default | Description |
|---|---|---|---|
| `DREAM_VAULT_ROOT` | path | `vault-paths.toml`'s `vault_root` | Override the vault root. Same as `--vault-root`. |
| `DREAM_OUTPUT_DIR` | path | `<vault-root>/dream-reports` | Override the report destination. Same as `--output-dir`. |
| `DREAM_MODEL` | string | `claude-sonnet-4-6` | Default model. CLI `--model` wins. |
| `DREAM_SINCE` | string | `7d` | Default scan window. CLI `--since` wins. |
| `DREAM_NO_MCP` | `0`/`1` | `0` | Set to `1` to force Tier 0 mode globally. CLI `--no-mcp` also works. |
| `DREAM_SESSIONS_ROOT` | path | `~/.claude/projects` | Override sessions JSONL root. |
| `DREAM_INDEX_FILE` | path | auto-discover | Single vault index file to update on apply. Same as `--index-file`. Leave unset to auto-discover `<vault-root>/<subdir>/wiki/index.md`. |
| `DREAM_CONFIG_DIR` | path | `<plugin>/config` | Override the directory `dream.sh` looks in for `vault-paths.toml`, `signal-patterns.toml`, `mcp-config.json`. Useful for testing alternative configs. |
| `DREAM_USAGE_LOG` | path | `<plugin>/.usage-log.jsonl` | Override the rolling cost log location. |
| `DREAM_VERBOSE` | `0`/`1` | `0` | Same as `--verbose`. |
| `ANTHROPIC_API_KEY` | string | from `claude` CLI auth | Standard Claude Code env var. Required only if your `claude` CLI isn't already authed. |

---

## Config files

Three TOML/JSON files in `config/` drive behavior. They ship as
`.example.*` templates; copy to the non-example name to activate.

### `config/vault-paths.toml`

Defines which directories the vault snapshot walks and the stale-detection
threshold.

**Schema:**

```toml
vault_root = "<absolute-path>"     # required
stale_days = <integer>             # required, days
frontmatter_only = [               # optional, glob list
  "<path-glob>",
]

[[subdirs]]                        # one block per directory to scan
name = "<relative-path-under-vault-root>"
description = "<human-readable label>"
weight = "high" | "medium" | "low" # optional, default "medium"
```

**Example:**

```toml
vault_root = "/Users/you/Documents/Obsidian"
stale_days = 60

[[subdirs]]
name = "persona"
description = "identity, role, goals, schedule"
weight = "high"

[[subdirs]]
name = "projects"
description = "active and archived projects"

[[subdirs]]
name = "fitness"
description = "training, body comp, nutrition"
weight = "medium"
```

The `weight` field tells the reconcile prompt how to prioritize. High-weight
subdirs get more attention from the LLM; low-weight ones are scanned but
flagged less aggressively.

See [`config/vault-paths.example.toml`](../skills/dream-skill/config/vault-paths.example.toml)
for the shipped template.

---

### `config/signal-patterns.toml`

Patterns used by `preprocess.py` to flag high-signal messages and suppress
noise. Authoritative spec; current implementation has these baked into the
script for speed.

**Schema:**

```toml
[high_signal]
verbs = ["<regex>", ...]
anchors = ["<regex>", ...]
entities = ["<literal string>", ...]

[noise]
patterns = ["<regex>", ...]

[filter]
short_reply_chars = <integer>
user_msg_max = <integer>
asst_msg_max = <integer>
```

**Example excerpt:**

```toml
[high_signal]
verbs = ["starting", "switched to", "shipped", "graduated", ...]
anchors = ["my role", "my goal", "current focus", ...]
entities = []   # add your companies, projects, key people here

[noise]
patterns = ["^I'll ", "^Sure[!,.] ", "^```", ...]
```

See [`config/signal-patterns.example.toml`](../skills/dream-skill/config/signal-patterns.example.toml)
for the shipped template.

**Customizing entities:** as you build out your persona vault and find that
specific company names, project names, or contact names matter for
reconciliation, add them to `entities`. Mentions of any entry get a `★`
marker in the preprocessed transcript.

---

### `config/mcp-config.json`

Defines MCP servers active during dream cycles. **Not auto-created** — only
generated by `setup.sh --mcp` or hand-edited.

See [`MCP-SETUP.md`](MCP-SETUP.md) for the full schema and per-MCP setup
walkthroughs. See [`config/mcp-config.example.json`](../skills/dream-skill/config/mcp-config.example.json)
for a starter template.

This file is gitignored. **Do not commit it.** It contains tokens.

---

## Common recipes

### "My vault is in a different directory"

```bash
export DREAM_VAULT_ROOT="/path/to/your/vault"
./dream.sh
```

Or edit `config/vault-paths.toml`:

```toml
vault_root = "/path/to/your/vault"
```

### "I want reports somewhere other than `<vault-root>/dream-reports/`"

```bash
./dream.sh --output-dir ~/Documents/dream-reports
```

Or via env:

```bash
export DREAM_OUTPUT_DIR=~/Documents/dream-reports
```

### "I want to use Opus instead of Sonnet"

```bash
./dream.sh --model claude-opus-4-7
```

Roughly 10x the cost per cycle. Use sparingly — for a quarterly deep audit,
not the weekly cycle.

### "I want to scan back further than 7 days"

```bash
./dream.sh --since 30d
```

Or:

```bash
./dream.sh --since 14d
```

The window applies to both session JSONL filtering and the reconcile prompt's
notion of "recent."

### "I want to run without any MCPs for one cycle"

```bash
./dream.sh --no-mcp
```

Useful when an MCP is timing out or returning errors — confirm the rest of the
pipeline works before diagnosing the MCP.

### "My vault has different category names"

Edit `config/vault-paths.toml`. The `[[subdirs]]` blocks are arbitrary — any
directory name under `vault_root` works.

### "I keep tokens at non-default paths"

Edit `config/mcp-config.json`. The `env` blocks for each MCP define where
credentials live. Absolute paths only (JSON doesn't expand `~`).

### "I want a quick cycle on the last 24 hours for a daily run"

```bash
./dream.sh --since 24h
```

Cheap on cost (small session window), useful if you want to bias toward
real-time accuracy.

### "I want to run weekly without thinking about it"

See the cron setup in [`INSTALL.md`](INSTALL.md#scheduling-with-cron).

### "I'm experimenting with prompts and don't want to spend money"

```bash
./dream.sh --dry-run --verbose
```

Inspect `/tmp/dream-sessions-<date>.md` and `/tmp/dream-vault-<date>.md`,
along with verbose logs from the preprocess and snapshot stages.

### "I want a different sessions root (testing, or non-standard install)"

```bash
./dream.sh --sessions-root /custom/path
```

Or:

```bash
export DREAM_SESSIONS_ROOT=/custom/path
```
