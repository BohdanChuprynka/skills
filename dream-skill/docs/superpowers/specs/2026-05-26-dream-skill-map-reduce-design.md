# dream-skill map-reduce upgrade — design

**Status:** design approved, awaiting implementation plan
**Author:** Claude + Bohdan (brainstorming session 2026-05-26)
**Affects:** dream-skill at `skills/dream-skill/` in the skills monorepo

## Problem statement

Dream-skill's reconcile stage sends a single LLM call containing the full preprocessed conversation transcript plus the vault snapshot. After the recent preprocess.py rewrite (signal filter removed, head+tail truncation, last-run resume, coding-dump heuristic), the transcript volume grew significantly to capture more persona signal:

- 7d window after filter: ~1.06 MB sessions.md (~265K tokens)
- 30d window after filter: ~3.04 MB sessions.md (~760K tokens)

Both exceed the 200K-token context cap of Claude Sonnet 4.6 under the Max subscription. The reconcile call either rejects, auto-truncates, or splits internally — none acceptable. We need a path that handles arbitrarily large windows without losing signal.

Pay-per-token paths (API key + 1M-context beta) were considered and rejected because Max subscription already covers Claude calls. The chosen path is map-reduce: split sessions.md into parallel chunks, extract persona signals per chunk via separate LLM calls, then run a single reduce call that synthesizes extracts plus vault state into the final dream report.

## Goals

1. Process arbitrarily large windows (within 8 chunks × 200K = ~1.6M-token theoretical ceiling)
2. Preserve persona signal fidelity comparable to a single-call run (no obvious gaps in the dream report)
3. Keep existing dream-report output format unchanged so downstream apply_auto.py needs no modification
4. Preserve the single-call path for small windows so quota is not wasted
5. Make extraction inspectable for tuning

## Non-goals

- Resume from partial failure (strict abort chosen for simplicity)
- Auto-retry on transient errors (user reruns)
- Sub-second optimization (wall time 5-8 min for chunked runs is acceptable)
- Map prompt as parameterized config (start with markdown file; revisit if iteration shows need)

## Architecture

```
dream.sh (orchestrator)
  |
  +-- Stage 1: preprocess.py        -> $TMP/sessions.md (existing)
  +-- Stage 2: load_vault_state.py  -> $TMP/vault.md    (existing)
  +-- Stage 2.5: count_tokens.py    -> N tokens         (NEW)
  |
  +-- if N < 130K tokens:  SINGLE-CALL PATH (existing, unchanged)
  |      \-- Stage 3: reduce (claude --print) -> dream-report.md
  |
  +-- if N >= 130K tokens: MAP-REDUCE PATH (NEW)
         |
         +-- Stage 3a: chunker.py
         |      \-- $TMP/chunks/chunk-{1..N}.md (time-bucketed, ~150K tokens each)
         |
         +-- Stage 3b: parallel map calls (bash & + wait)
         |      \-- claude --print --append-system-prompt prompts/map-system.md
         |          for each chunk, in parallel
         |      \-- $TMP/extracts/extract-{1..N}.md
         |
         +-- Stage 3c: concatenate extracts
         |      \-- $TMP/extracts-concat.md with "=== CHUNK N ===" separators
         |
         +-- Stage 3d: reduce call
         |      \-- claude --print --append-system-prompt prompts/system.md
         |          with --mcp-config (MCPs active)
         |          reconcile.md template, {SESSIONS} = extracts-concat
         |      \-- dream-report.md (same format as today)
         |
         +-- Stage 4: save + log + stamp .last-run
                \-- $OUTPUT_DIR/dream-<date>.md         (existing)
                \-- $OUTPUT_DIR/dream-extracts-<date>/  (NEW, gitignored)
                \-- $OUTPUT_DIR/dream-errors-<date>/    (NEW, only on failure)
                \-- $SKILL_DIR/.usage-log.jsonl extended with chunk fields
                \-- $SKILL_DIR/.last-run stamp
```

Key invariants:

- `apply_auto.py` and `apply_undo.sh` are untouched; the reduce step still produces today's dream-report format.
- MCP tools (Notion, Calendar, Gmail) are active only in the reduce call, not in map calls. Map is pure local extraction.
- Strict abort: any non-zero exit code in any stage kills the script. No partial outputs are written to the output directory (other than preserved error logs).
- Single-call path is preserved verbatim for windows under the threshold so quota is not wasted on small runs.

## Components

### dream.sh (modified)

**Role:** orchestrator.
**Changes:**
- After Stage 2, invoke `count_tokens.py` on `$TMP/sessions.md`.
- If under 130K tokens, take the existing single-call path (no changes).
- If at or above 130K tokens, run the new chunked path (Stages 3a-3d).
- Install a custom EXIT trap that, on non-zero exit, copies `$TMP/responses/error-*.log` to `$OUTPUT_DIR/dream-errors-<date>/` before deleting `$TMP`.
- Extend `.usage-log.jsonl` row with `chunked: bool`, `chunk_count: N`, `map_token_totals: {input, output, cache_read, cache_creation}`, `reduce_token_totals: {...}`.
- Add `--force-chunked` flag (force map-reduce path even below threshold; for testing).
- Add `--force-single` flag (force single-call path even above threshold; will fail if Claude rejects).

### scripts/chunker.py (NEW)

**Role:** split sessions.md by date range into chunk files.
**Input:** `--input sessions.md --output-dir $TMP/chunks/ --target-tokens 150000 [--min 2] [--max 8]`
**Output:** `chunk-1.md` through `chunk-N.md` in the output directory; prints metadata (chunk count, date ranges, token counts) to stdout.
**Algorithm:**
1. Read sessions.md, parse session-header lines (`--- <source> YYYY-MM-DD HH:MM ---`).
2. Bucket entire session blocks (header + body until next header) by their start timestamp.
3. Compute target chunk count: `N = ceil(total_tokens / target_tokens)`, clamped to `[min, max]`.
4. Divide the time window equally into N slices.
5. Assign each session to the slice containing its start timestamp.
6. Write each non-empty slice as `chunk-{i}.md`.
**Depends on:** `count_tokens.py` (inline-importable function).

### scripts/count_tokens.py (NEW)

**Role:** count tokens in a file.
**Input:** path argument or `-` for stdin.
**Output:** single integer to stdout.
**Strategy:**
- Try `import tiktoken; enc = tiktoken.get_encoding("cl100k_base")`. Use `len(enc.encode(text))`.
- On ImportError, fall back to `int(len(text) / 3.5)`; warn once to stderr that tiktoken is unavailable.

### prompts/map.md (NEW)

User-message template for map calls. Placeholders: `{TODAY}`, `{CHUNK_RANGE}`, `{CHUNK_CONTENT}`.

```markdown
Extract persona signals from the following local-conversation transcript chunk.

Today's date: {TODAY}
Chunk date range: {CHUNK_RANGE}

=== TRANSCRIPT ===
{CHUNK_CONTENT}

Produce extraction output per your system prompt.
```

### prompts/map-system.md (NEW)

System prompt for map calls. Defines what counts as a persona signal, the loose-markdown output format, and hard rules forbidding dream-report sections, frontmatter, MCP tool use, and recommendations. Targets <2KB output per chunk.

Initial draft (subject to tuning during first 2-3 chunked runs):

```markdown
You are extracting persona-relevant signals from a chunk of a user's local
conversation transcripts. You are NOT reconciling against a vault, producing a
dream report, or making recommendations. Your sole job is signal extraction.

## What counts as a persona signal

The user maintains an Obsidian vault that models them AS A PERSON — identity,
life-state, preferences, relationships, body, schedule, goals. The vault is a
persona model, not a project archive.

KEEP (persona-relevant):
- State changes: jobs, projects, schools, relationships, programs, gyms, locations
- Decisions: new commitments, dropped commitments, pivots, plans
- New entities: people mentioned, companies/programs joined, mentors, friends
- Soft signals: recurring themes, things the user is excited/worried about
- Observed contradictions: statements that may conflict with prior context
- Recent themes: rolling-attention items, what's on the user's mind

IGNORE (work-output, not persona):
- Code-task content (implementations, debugging, refactoring, build logs)
- Project-output telemetry (commits, file edits, deploys)
- General programming/tech questions
- Tool-use plumbing

## Output format

Loose markdown. Use these section headers when applicable, omit empty sections:

## State changes
## Decisions
## New entities
## Soft signals
## Observed contradictions
## Recent themes

Each entry: one bullet with the signal, dates if available, session reference.

## Hard rules

- NO YAML frontmatter
- NO dream-report sections (no "## Auto-apply", "## Needs confirmation", etc.)
- NO recommendations or proposals — extraction only
- NO MCP tool use (you don't have those tools here)
- If chunk has zero persona signal: output just "No persona-relevant signals in this chunk."
- Target output: under 2KB
```

The design constraint is that this prompt must NOT include the MCP-tools or reconciliation-protocol material from system.md.

### prompts/reconcile.md (modified)

Existing template gets one paragraph added after the `=== CONVERSATION SIGNALS ===` block explaining that in chunked mode the block contains per-chunk pre-extracted signal lists rather than raw conversation, delimited by `=== CHUNK N ===` markers, with chunk references citable for triangulation.

### prompts/system.md (modified)

Existing system prompt gets one paragraph explaining the dual-path architecture, so the LLM understands whether the SESSIONS block contains raw transcripts or pre-extracted summaries.

### Output artifacts (NEW)

- `$OUTPUT_DIR/dream-extracts-<date>/chunk-{1..N}.md` — preserved map outputs, gitignored, for audit and prompt tuning.
- `$OUTPUT_DIR/dream-errors-<date>/error-{N}.log` — written only on failure; preserves stderr per failed chunk for debugging.

## Data flow (chunked path)

1. `preprocess.py` writes `$TMP/sessions.md`.
2. `load_vault_state.py` writes `$TMP/vault.md`.
3. `count_tokens.py` reports N tokens for sessions.md.
4. If N >= 130K, `chunker.py` writes `$TMP/chunks/chunk-{1..K}.md` where `K = clamp(ceil(N/150K), 2, 8)`.
5. For each chunk, dream.sh substitutes `{TODAY}`, `{CHUNK_RANGE}`, `{CHUNK_CONTENT}` into `prompts/map.md` and launches `claude --print --output-format json --append-system-prompt "$(cat prompts/map-system.md)" --tools "" --permission-mode bypassPermissions "<prompt>"` in the background with output redirected to `$TMP/responses/response-{k}.json` and stderr to `$TMP/responses/error-{k}.log`. PIDs collected in an array.
6. `wait $pid` per collected PID. Any non-zero exit -> `exit 1` for dream.sh.
7. For each response JSON, dream.sh extracts the `result` field and writes `$TMP/extracts/extract-{k}.md`.
8. dream.sh concatenates extracts in order with `=== CHUNK k (date_range) ===` separators -> `$TMP/extracts-concat.md`.
9. dream.sh substitutes `{TODAY}`, `{WINDOW}`, `{SESSIONS}=extracts-concat`, `{VAULT}` into `prompts/reconcile.md` and runs a single `claude --print` call with the existing system.md, MCP config active.
10. Response parsed, frontmatter stripped of any preamble, dream-report written to `$OUTPUT_DIR/dream-<date>.md` (existing logic).
11. Extracts copied to `$OUTPUT_DIR/dream-extracts-<date>/`.
12. Usage log row appended; `.last-run` stamped.

## Error handling

Strict abort policy: any non-zero exit code anywhere kills the script. User reruns. No partial dream reports written.

| Failure | Detection | Behavior |
|---|---|---|
| preprocess/chunker/count-tokens failure | exit code != 0 | set -e kills dream.sh |
| Any map call fails (network, claude error, timeout) | `wait $pid` non-zero | dream.sh prints which chunk failed and exits 1 |
| Map call hangs | `timeout 600 claude ...` wrapper | Process killed at 600s, counted as failure |
| Map response empty (0 bytes after extraction) | file-size check | Treated as map failure |
| Reduce step fails | exit code != 0 | set -e kills; map outputs lost on cleanup |
| MCP server errors during reduce | LLM handles per existing system.md | Note absence, continue |

On any failure, the EXIT trap copies `$TMP/responses/error-*.log` to `$OUTPUT_DIR/dream-errors-<date>/` before cleaning `$TMP`. Successful runs skip this copy.

## Edge cases

| Case | Handling |
|---|---|
| Empty sessions.md (last-run was recent) | tokens=0 -> single-call path -> trivial reduce |
| Threshold edge (130-150K tokens) | chunker `min=2` splits into 2 even if `ceil(total/150K)=1` |
| Very large window (90d+, >1.2M tokens) | clamp to 8 chunks; if per-chunk size >200K, map call fails at LLM, strict abort |
| tiktoken not installed | fall back to bytes/3.5 estimate, warn once |
| `--force-chunked` with 50K tokens | chunker creates 2 chunks of ~25K each, runs fine |
| `--force-single` with 500K tokens | claude rejects with context overflow, set -e kills |
| Map LLM returns frontmatter or refuses | reduce step receives whatever map emitted; not validated |
| One chunk has no persona signal | extract is the placeholder line "No persona-relevant signals in this chunk."; reduce works normally |
| Concurrent dream.sh runs | out of scope (race on .last-run and output) |
| `--apply` short-path | unchanged, doesn't touch new code |

## Observability

- chunker.py prints chunk count and date ranges to stdout.
- dream.sh prints `[3a/4] chunk into K chunks (target 150K tokens each)`, `[3b/4] running K parallel map calls`, etc., to mirror existing 1/4..4/4 stage messages.
- Map call results preserved in `$OUTPUT_DIR/dream-extracts-<date>/` for inspection.
- Error logs preserved on failure in `$OUTPUT_DIR/dream-errors-<date>/`.
- `.usage-log.jsonl` row extended with `chunked`, `chunk_count`, `map_token_totals`, `reduce_token_totals`.

## Testing strategy

### Deterministic (no LLM)

- `chunker.py` unit test: synthetic sessions.md with N session headers spanning T days; assert expected chunk count, correct date boundaries, min/max enforcement.
- `count_tokens.py` parity test: sample file via tiktoken vs bytes-fallback within ~15%.
- dream.sh routing dry-run: mock `claude` as `cat`; verify correct route at the 130K boundary.
- Bash background-process integration: mock `claude` as `sleep N && echo`; verify dream.sh detects failure on `exit 1` injection.

### LLM-dependent smoke checks (manual)

- `--force-chunked` on a 7d window: produces dream report structurally identical to single-call output; extracts dir contains N files.
- Real 30d window run: completes without abort; wall time <10 min; dream report passes manual sanity review.
- `--force-single` on 7d (regression): existing behavior unchanged.
- Map extract spot-check: open `dream-extracts-<date>/chunk-N.md`; confirm sections populated, no frontmatter, target <2KB.

### Iteration

The map prompt is the most likely thing to need tuning. First 2-3 chunked runs:

1. Open extracts, read each `chunk-N.md`.
2. Read corresponding dream report.
3. Identify signals that ENTERED the dream report from extracts (map worked).
4. Identify signals present in raw sessions but ABSENT from the dream report (map missed).
5. Tune map prompt accordingly. Prefer false positives (keep borderline) over false negatives (drop persona-relevant).

## Migration / backward compatibility

- `.last-run`, `.usage-log.jsonl`, dream-report.md format: unchanged.
- `apply_auto.py`, `apply_undo.sh`: unchanged.
- Existing single-call path preserved verbatim for windows below threshold.
- New files are additive.
- Existing `--apply` short-path unchanged.

No migration script needed. After shipping, the next run uses the new path automatically when the threshold is hit.

## Out of scope (deferred)

- Resume from partial map failure
- Auto-retry on transient failures
- Map prompt as TOML/JSON config (markdown file is sufficient initially)
- Token-budget alerting (chunker just produces files; claude rejects on overrun)
- Sequential fallback if parallel collides with rate limits

## File summary

### New files (5)
- `scripts/chunker.py`
- `scripts/count_tokens.py`
- `prompts/map.md`
- `prompts/map-system.md`
- (output) `dream-extracts-<date>/` and `dream-errors-<date>/` directories at runtime

### Modified files (3)
- `dream.sh`
- `prompts/reconcile.md`
- `prompts/system.md`

### Unchanged files
- `scripts/preprocess.py` (just rewrote, no further changes)
- `scripts/load_vault_state.py`
- `scripts/apply_auto.py`
- `scripts/apply_undo.sh`
- `setup.sh`, `doctor.sh`
- `SKILL.md` (may want a one-line addition mentioning chunked path, but not required)
- `config/*` (no schema changes)
