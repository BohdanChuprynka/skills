# Architecture

Audience: contributors and advanced users. Reference for how the four pipeline
stages compose, what each one reads and writes, and where the extension points
are.

---

## 1. System overview

```
                       ┌──────────────────────────────┐
                       │  Claude Code session JSONLs  │
                       │  ~/.claude/projects/*/*.jsonl│
                       └──────────────┬───────────────┘
                                      │
                                      ▼
                       ┌──────────────────────────────┐
                       │  Stage 1: preprocess.py      │
                       │  (Python, no LLM, free)      │
                       │  Filters → cleaned transcript│
                       └──────────────┬───────────────┘
                                      │  sessions.md
                                      │
   ┌──────────────────┐               │
   │  Vault root      │               │
   │  (markdown dirs) │               │
   └────────┬─────────┘               │
            │                         │
            ▼                         │
   ┌──────────────────────────┐       │
   │  Stage 2: load_vault     │       │
   │  _state.py               │       │
   │  (Python, no LLM, free)  │       │
   │  Frontmatter + sections  │       │
   └────────┬─────────────────┘       │
            │  vault.md               │
            │                         │
            ▼                         ▼
   ┌──────────────────────────────────────────────┐
   │  Stage 3: Reconcile via Claude               │
   │  claude --mcp-config <plugin>/config/        │
   │         mcp-config.json --strict-mcp-config  │
   │  System prompt + reconcile template          │
   │  Optional MCPs: Filesystem/Notion/GCal/Gmail │
   │  ~$0.10 per Sonnet cycle with caching        │
   └────────┬─────────────────────────────────────┘
            │  dream-<YYYY-MM-DD>.md
            │
            ▼
   ┌──────────────────────────────────────────────┐
   │  Stage 4: Apply (manual, separate command)   │
   │  scripts/apply_auto.py --report <path>       │
   │  Confidence-gated edits to vault pages       │
   │  Rollback log written before any change      │
   └──────────────────────────────────────────────┘
```

Stages 1 and 2 are pure local Python. Stage 3 is the only LLM call. Stage 4 is
user-driven and never fires from `dream.sh` itself — the script ends after
writing the report.

---

## 2. Stage 1: Preprocess

**Script:** `scripts/preprocess.py`

**Input:** all `*.jsonl` files under `~/.claude/projects/` whose `mtime` is
within the `--since` window.

**Output:** a single markdown transcript (default to stdout, captured to
`$TMP/sessions.md` by `dream.sh`).

### What it does

The session JSONLs are noisy. Each contains every assistant turn, tool call,
tool result, hook output, system reminder, and bash transcript. The
reconciliation cycle only cares about **what the user said and revealed about
themselves** — assistant turns are mostly conversational scaffolding.

Preprocessing applies three filters:

1. **User-message bias.** User messages are always kept (subject to noise
   filters). Assistant turns are *dropped by default*, kept only as Q/A
   anchors for short user replies.
2. **QA-anchor heuristic.** If a user message is ≤ `short_reply_chars` (60 by
   default), the preceding assistant message is also kept — otherwise the
   short reply has no context. ("yes", "no, that one" mean nothing without
   the question.)
3. **Signal pattern matching.** Lines matching patterns from
   `config/signal-patterns.toml` get a `★` prefix in the output. This marker
   does **not** drop other content — it just makes high-signal lines findable.

### What gets filtered out

The `[noise]` block in `signal-patterns.toml` defines prefixes that mark a
message as system/hook chatter, dropped entirely:

- `<system-reminder` blocks
- Slash-command echoes (`<command-name>`, `<command-args>`)
- Local command stdout/stderr captures
- Bash tool result blocks
- User-prompt-submit-hook content
- The Claude Code "Caveat" preamble

### Truncation

Messages longer than `user_msg_max` (1500) or `asst_msg_max` (1000) are
truncated with an ellipsis. This caps absolute token spend on Stage 3 even if
someone pastes a giant code block into a chat.

### Configuration

The patterns themselves live in `config/signal-patterns.toml`. The current
implementation has them baked into `preprocess.py` for speed; the TOML file is
the authoritative spec. To tune patterns, edit both (or just the script for
now — the TOML drives the next iteration).

---

## 3. Stage 2: Vault snapshot

**Script:** `scripts/load_vault_state.py`

**Input:** `config/vault-paths.toml` (which dirs to scan) + the vault root.

**Output:** a compact markdown summary of the vault state.

### What it extracts

For each markdown page under the configured subdirs:

- **Title** (first H1 or filename)
- **Frontmatter** (YAML between leading `---` fences):
  - `status:` — `active`, `archived`, `completed`, `needs_verification`, etc.
  - `updated:` — date of last frontmatter touch
  - `tags:` — tag list
- **Section summary** — H2/H3 headings only, no body content. Keeps tokens
  manageable on long pages.

Pages matching the `frontmatter_only` glob list have only frontmatter
extracted (no section headings either). Use this for very long reference
pages.

### Stale detection

Pages with `updated:` older than `stale_days` (default 60) are flagged as
**stale candidates** in the snapshot output. The LLM uses this signal to
decide whether content from sessions in the window contradicts a long-stable
fact (high suspicion) versus a recently-touched assertion (low suspicion).

### Output schema

The snapshot is markdown, structured roughly as:

```markdown
# Vault snapshot — <vault-root>

## persona/ (or whatever your first subdir is)
- role.md (updated: 2026-04-12, status: active)
  ## Current role
  ## Background
  ## Goals

- skills.md (updated: 2024-08-01, status: needs_verification) [STALE]
  ## Technical skills
  ...
```

Bytes are counted and surfaced in the `dream.sh` log line so you can
monitor whether the snapshot is growing unbounded.

---

## 4. Stage 3: Reconcile

This is the only stage that costs money. `dream.sh` invokes:

```bash
claude --mcp-config "$PLUGIN_DIR/config/mcp-config.json" \
       --strict-mcp-config \
       --model "$MODEL" \
       --print \
       --output-format json \
       --tools "" \
       --permission-mode bypassPermissions \
       --append-system-prompt "$SYSTEM_PROMPT" \
       "$RECONCILE_PROMPT"
```

### The LLM contract

- **System prompt** (`prompts/system.md`): defines persona-vault scope,
  proposal format, confidence levels, the "track who the user is, not what
  they produced" principle, frontmatter conventions.
- **User message** (`prompts/reconcile.md` with substituted `{WINDOW}`,
  `{SESSIONS}`, `{VAULT}`): the actual task. Contains both inputs verbatim.
- **`--tools ""`**: no built-in tools (no Read/Edit/Bash). The model can only
  use MCP tools, and only those in this run's MCP config.
- **`--strict-mcp-config`**: hard guarantee that no other MCPs leak in.
- **`--output-format json`**: response captured as JSON so we can extract
  usage stats + cost alongside the report markdown.

### Why MCP isolation matters

If MCPs from your daily Claude config leaked into dream cycles, two problems:

1. **Cost.** Every MCP description bloats the system prompt. A heavy daily
   setup with 10 integrations could double the input tokens of every cycle.
2. **Pollution.** Dream cycles produce vault edits. You do **not** want a
   misconfigured MCP from another context taking actions in your vault.
   `--strict-mcp-config` makes this structurally impossible.

The inverse also holds: daily Claude sessions never see the dream-skill
MCPs, so the dream config's tokens never appear in unrelated contexts.

### Cost characteristics

Per Sonnet 4.6 cycle with prompt caching:

- ~3-5k input tokens fresh (the reconcile template + system prompt + delta
  from previous cache hit)
- ~30-50k input tokens cached (the bulk of sessions + vault)
- ~1-3k output tokens (the report itself)

Without caching: 30-50k fresh input each cycle. Caching is enabled by default
on the Anthropic API; you get it for free.

See [`CONFIGURATION.md`](CONFIGURATION.md) for model overrides (e.g., Opus).

---

## 5. Stage 4: Apply (manual)

**Script:** `scripts/apply_auto.py`

`dream.sh` deliberately ends after writing the report. Applying changes to
the vault is a **separate, user-driven step**. The intent: a human reads the
report first, then runs apply with explicit `--drop` flags for anything they
don't want.

### Proposal-evidence-confidence model

Every proposal in the report has:

- **Title** — short summary ("Update current employer to Acme Corp")
- **Evidence** — the session quote(s) that triggered it
- **Confidence** — `high` / `medium` / `low`
- **Action** — what would change (frontmatter edit, body section update,
  new page creation, page archival)
- **Target** — vault path + line range

### Confidence gates

In v0.3+, `apply_auto.py --apply` will:

- Auto-apply `high`-confidence proposals
- Surface `medium` ones for one-click confirmation
- Defer `low` and contradictions for human resolution

In v0.1/v0.2, `apply_auto.py` is a stub that summarizes proposals; the human
does the edits.

### Rollback log

Before any vault edit, `apply_auto.py --apply` writes a rollback record:

```json
{
  "date": "2026-05-13",
  "applied": [
    {
      "path": "persona/role.md",
      "before_sha": "<git-style sha>",
      "after_sha": "<sha>",
      "diff": "<unified diff>"
    }
  ]
}
```

Stored at `<vault-root>/dream-rollback/dream-rollback-<date>.json`.
`scripts/apply_undo.sh <date>` reverses everything in that log.

### Channel detection

The script also chooses **where** to write proposals that don't have an
obvious target. New skills/interests might land in a `notes/` page. New
project mentions might land as a new `projects/<name>.md` page. The logic is
intentionally simple — when in doubt, the proposal is left in the inbox
report for human routing.

### Vault index updates

After every successful apply, dream-skill keeps the vault's content catalog
in sync. For each updated page, it looks for an `index.md` in the same
subdir-with-`wiki/`-convention and appends a list entry if the page isn't
already linked.

Resolution order:

1. `--index-file <path>` flag (or `DREAM_INDEX_FILE` env var) — single index
   updated for every applied edit.
2. Auto-discover `<vault-root>/<subdir>/wiki/index.md` for each edit.
3. Fallback `<vault-root>/<subdir>/index.md`.
4. Skip silently if nothing is found.

The update is idempotent: existing links (both markdown `[label](path.md)`
and Obsidian `[[wikilink]]` forms) cause the call to be a no-op so curated
descriptions aren't clobbered. Index edits are recorded in the cycle's
rollback file under `index_edits` so `apply_undo.sh <date>` reverses them
along with the page edits.

`--no-index-update` disables the step. Useful when you maintain indexes by
hand or your vault has no central catalog.

---

## 6. Output schema

A dream report is a single markdown file with YAML frontmatter:

```markdown
---
date: 2026-05-13
window: 7d
model: claude-sonnet-4-6
input_tokens: 4523
output_tokens: 1842
cost_usd: 0.078
proposals_count: 12
---

# Dream report — 2026-05-13

## Auto-applied (high confidence)
<empty in v0.1/v0.2; populated in v0.3>

## Needs your confirmation (medium confidence)

### Update current focus to Project Phoenix

**Confidence:** medium
**Evidence:**
- "we're now building Project Phoenix instead of the old roadmap" (session 2026-05-09)

**Target:** persona/role.md
**Action:** replace `current_focus` line in frontmatter

[Apply] [Skip] [Edit]

---

## Open contradictions (low confidence)

### Vault says role X, session says role Y

...

---

## Captured signals not acted on

- Mention of "new running routine" — possible body/fitness vault update
  (no fitness vault configured)
- ...
```

The frontmatter `proposals_count`, `cost_usd`, and `input_tokens` fields are
machine-readable for cost tracking dashboards.

---

## 7. MCP isolation contract

The full isolation story:

| Concern | Mechanism |
|---|---|
| Daily Claude sessions don't see dream MCPs | `dream.sh` uses `--mcp-config <plugin>/config/mcp-config.json`; daily sessions use the default global config |
| Dream cycle doesn't load global MCPs | `--strict-mcp-config` |
| Tokens don't enter shell environment | Tokens live in `config/mcp-config.json`'s `env` blocks, passed only to the spawned MCP subprocesses |
| Tokens don't end up in git | `.gitignore` excludes `config/mcp-config.json` (only `.example.json` is committed) |
| File access is sandboxed | Filesystem MCP enforces `realpath` sandboxing on allowed dirs |

If you ever debug an unexpected tool call or vault edit, the contract above is
the audit trail. Every variable above is observable.

---

## 8. Cost model

| Cadence | Model | Per cycle | Per month |
|---|---|---|---|
| Weekly | Sonnet 4.6 + caching | ~$0.08 | ~$0.35 |
| Daily | Sonnet 4.6 + caching | ~$0.08 | ~$2.40 |
| Weekly | Opus 4.7 + caching | ~$1.20 | ~$5.00 |

Cache hits dominate after the first run in a session. The cache window is
~5 minutes by default; running multiple cycles back-to-back gets near-100%
cache hit. The vault snapshot changes slowly, which is the main cache
beneficiary.

Cost spikes when:

- Vault grows significantly (more pages = bigger snapshot)
- Session activity over the window grows (more JSONLs to preprocess into
  the transcript)
- You bump to Opus
- You shorten the `--since` window dramatically and run frequently (fewer
  hits relative to setup overhead)

The `.usage-log.jsonl` rolling log captures every cycle's actual cost. Inspect
periodically:

```bash
jq -s 'map(.cost_usd) | add' ~/.claude/skills/dream-skill/.usage-log.jsonl
```

---

## 9. Data flow

| Source | Reader | Sink |
|---|---|---|
| `~/.claude/projects/*/*.jsonl` | `preprocess.py` | `$TMP/sessions.md` |
| `<vault-root>/<subdirs>/**/*.md` | `load_vault_state.py` | `$TMP/vault.md` |
| `config/vault-paths.toml` | `load_vault_state.py` | (used internally) |
| `config/signal-patterns.toml` | `preprocess.py` (spec) | (baked into script for now) |
| `config/mcp-config.json` | `claude` (via `--mcp-config`) | MCPs available during reconcile |
| `prompts/system.md` | `dream.sh` | `--append-system-prompt` arg |
| `prompts/reconcile.md` | `dream.sh` | user message arg |
| `$TMP/sessions.md` + `$TMP/vault.md` | substituted into reconcile prompt | LLM input |
| LLM stdout | `dream.sh` JSON parser | `<vault-root>/dream-reports/dream-<date>.md` |
| LLM JSON `usage` block | `dream.sh` JSON parser | `.usage-log.jsonl` (append) |
| Dream report | `apply_auto.py` (later, user-invoked) | vault page edits + rollback log |

---

## 10. Extension points

### Add a new signal source (new MCP)

1. Pick a local stdio MCP package. Must support `npx -y <package>`.
2. Add a server block to `config/mcp-config.json`:

   ```json
   "my-new-source": {
     "command": "npx",
     "args": ["-y", "package-name"],
     "env": { "API_TOKEN": "..." }
   }
   ```

3. Update `prompts/reconcile.md` to instruct the LLM to query that source.
4. Run `dream.sh --dry-run` and inspect the cycle's tool calls (in the JSON
   response) to confirm the new MCP is being queried.

### Add a new vault category

1. Add a `[[subdirs]]` block to `config/vault-paths.toml`:

   ```toml
   [[subdirs]]
   name = "my-category"
   description = "what lives here"
   ```

2. The script picks it up on next run. No code change needed.

### Add a new reconciliation rule

1. Edit `prompts/system.md`. The system prompt is where rules like "treat
   `status: archived` as past-tense" and "the user corrects themselves; accept
   it" live.
2. Run a few cycles to validate the change doesn't regress existing
   reconciliation quality.

### Add a new signal pattern

1. Edit `config/signal-patterns.toml`. Adjust the `[high_signal]` regex
   lists or add custom entities.
2. For now, also mirror the change into `scripts/preprocess.py` (the script
   has them baked in for speed; the TOML is the spec until the script reads
   the TOML directly).

### Change the report destination

Set `DREAM_OUTPUT_DIR` env var or pass `--output-dir` to `dream.sh`. See
[`CONFIGURATION.md`](CONFIGURATION.md) for the full precedence rules.
