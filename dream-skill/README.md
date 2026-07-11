# dream-skill

Dream synchronizes durable personal context from local Claude Code and Codex conversations into configured Obsidian persona vaults.

It is an explicit or scheduled batch pipeline. It does not auto-write on session close.

## What It Keeps

- identity, relationships, preferences, goals, health, schedule, and life state
- durable project purpose, architecture, constraints, decisions, and active blockers
- current work context that will matter in later conversations

It drops commits, command histories, file lists, test receipts, temporary debugging, and detailed agent work narration.

## Pipeline

1. **FIND** selects unprocessed Claude and Codex transcripts and excludes private chats and subagents.
2. **MAP** strips tool noise, preserves role/event provenance, and extracts compact facts with exact evidence spans.
3. **REDUCE** performs conservative local TF-IDF deduplication and creates content-derived stable IDs.
4. **ROUTE** uses local weighted BM25 to retrieve a bounded canonical-page allow-list, then a low-effort agent chooses within it.
5. **RECONCILE** compares candidates with bounded target-page context. Small isolated pages are packed to amortize agent overhead.
6. **APPLY** writes safe direct-user facts or stages uncertain/destructive changes with review sidecars.
7. **RECEIPT/METRICS** records a readable receipt and content-free run measurements.
8. **MARKER** advances exact source cursors only after every required stage succeeds.

Batch agents run in a read-only sandbox. Deterministic validators derive target, mode, confidence, review gates, and Markdown mechanics locally.

## Agent engines

Dream uses the Codex CLI by default. Select the agent engine explicitly when a
canary or recovery needs a different provider:

```bash
python3 scripts/dream-run.py --engine codex --shadow --source all
python3 scripts/dream-run.py --engine claude --shadow --source all
```

`codex` uses the configured Codex models and reasoning efforts. `claude` uses
Haiku for MAP, ROUTE, and RECONCILE by default; model overrides remain
available per stage. Choose an engine with `--engine` or `DREAM_ENGINE`; the
selection is intentionally environment-only, not persisted in `config.toml`.

For a low-cost scheduled Codex canary, set these environment variables before
running the shipped pipeline:

```bash
export DREAM_ENGINE=codex
export DREAM_MAP_MODEL=gpt-5.6-luna DREAM_MAP_EFFORT=low
export DREAM_ROUTE_MODEL=gpt-5.6-luna DREAM_ROUTE_EFFORT=low
export DREAM_RECONCILE_MODEL=gpt-5.6-luna DREAM_RECONCILE_EFFORT=low
```

## Install

```bash
./setup.sh
```

The installer:

- symlinks the Claude skill to `skills/dream-skill/`
- creates a self-contained Codex copy under `~/.codex/skills/dream-skill/`
- preserves `~/.claude/dream-skill/config.toml`
- creates private runtime directories with mode `0700`

Configure vault roots in `~/.claude/dream-skill/config.toml`.
Start from the sanitized `config.example.toml`; real vault paths and optional
people-routing terms stay local.

## Run

From Claude Code:

```text
/dream-skill --shadow
/dream-skill
```

From Codex:

```text
Use $dream-skill --shadow
Use $dream-skill
```

Useful flags:

| Flag | Behavior |
|---|---|
| `--shadow` | Full canary; no vault, queue, receipt, or production-marker mutation |
| `--dry-run` | One-off operator preview |
| `--since YYYY-MM-DD` | Override the start of the source window |
| `--all` | Deliberate weekly-batched history replay |
| `--source claude|codex|all` | Select transcript sources |
| `--engine codex|claude` | Select the CLI used for MAP, ROUTE, and RECONCILE |
| `--resume RUN_ID` | Resume a retained run with its exact time boundary |
| `--promote-shadow` | Explicitly resume a reviewed shadow run as a real write |
| `--ignore` / `--unignore` | Mark or unmark the current transcript as private |

Shadow canaries use separate cursors under `shadow-markers/`; they never move production source markers.
They retain private per-run artifacts, gap diagnostics, metrics, and state only.

## Safety

- Vault roots come only from `config.toml`.
- New pages are never invented automatically.
- Any uncertain or destructive change is review-only.
- Supersede and contradict require one exact old Markdown line.
- Failed approvals retain queue entries and sidecars.
- No-op retries do not create undo records.
- Stable candidate IDs prevent cross-run review collisions.
- A failed stage cannot advance a production marker.
- Failed workdirs remain resumable; successful sensitive workdirs are removed by default.

## Review

Build and serve the queue:

```bash
DREAM_HOME="${DREAM_HOME:-$HOME/.claude/dream-skill}"
python3 scripts/build-review-queue.py \
  --pending-md "$DREAM_HOME/queue/pending.md" \
  --sidecars-dir "$DREAM_HOME/queue/sidecars" \
  --output "$DREAM_HOME/queue/review-input.json" \
  --existing-decisions "$DREAM_HOME/queue/review-decisions.json"
python3 scripts/serve-review.py
```

The review server uses only Python's standard library, binds to loopback, requires a per-run CSRF token, and applies a restrictive content-security policy.

## Operations

```bash
python3 scripts/dream-health.py --human
tests/run.sh
```

Health reports marker age, failed runs, queue/sidecar integrity, routing-gap counts, storage, and unsafe permissions without printing candidate content.

Private routing diagnostics are stored under `~/.claude/dream-skill/gaps/`. Content-free metrics include tokens, role/confidence/type distributions, route gaps, duplicate rate, and review outcomes.

The runtime uses local BM25 and pure-Python TF-IDF. Embeddings are intentionally deferred until measured misses show that bounded lexical retrieval is insufficient.
