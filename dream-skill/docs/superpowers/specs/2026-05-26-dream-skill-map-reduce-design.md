# dream-skill map-reduce upgrade — design

**Status:** v2 — incorporates smoke-test findings (2026-05-26)
**Author:** Claude + Bohdan (brainstorming session 2026-05-26)
**Affects:** dream-skill at `skills/dream-skill/` in the skills monorepo

## Problem statement

Dream-skill's reconcile stage sends a single LLM call containing the full preprocessed conversation transcript plus the vault snapshot. After the recent preprocess.py rewrite (signal filter removed, head+tail truncation, last-run resume, coding-dump heuristic), the transcript volume grew significantly to capture more persona signal:

- 7d window after filter: ~1.06 MB sessions.md (~265K tokens)
- 30d window after filter: ~3.04 MB sessions.md (~760K tokens)

Both exceed the 200K-token context cap of Claude Sonnet 4.6 under the Max subscription. The reconcile call either rejects, auto-truncates, or splits internally — none acceptable. We need a path that handles arbitrarily large windows without losing signal.

Pay-per-token paths (API key + 1M-context beta) were considered and rejected because Max subscription already covers Claude calls. The chosen path is map-reduce: split sessions.md into parallel chunks, extract persona signals per chunk via separate Haiku calls, then run a single Sonnet reduce call that synthesizes extracts plus vault state into the final dream report.

## Goals

1. Process arbitrarily large windows (within 8 chunks × 200K = ~1.6M-token theoretical ceiling)
2. Preserve persona signal fidelity comparable to a single-call run
3. Keep existing dream-report output format unchanged so downstream `apply_auto.py` needs no modification
4. Preserve the single-call path for small windows so quota is not wasted
5. Make extraction inspectable for tuning
6. Avoid contaminating `~/.claude/projects/` with self-generated sessions (feedback loop prevention)

## Non-goals

- Resume from partial failure (strict abort chosen for simplicity)
- Auto-retry on transient errors (user reruns)
- Sub-second optimization (wall time 5-8 min for chunked runs is acceptable)
- Map prompt as parameterized config (markdown file is sufficient initially)

## Architecture

```
dream.sh (orchestrator)
  |
  +-- Stage 1: preprocess.py        -> $TMP/sessions.md (existing)
  +-- Stage 2: load_vault_state.py  -> $TMP/vault.md    (existing)
  +-- Stage 2.5: count_tokens.py    -> N tokens         (NEW; counts sessions + vault + prompt overhead)
  |
  +-- if N < 130K tokens:  SINGLE-CALL PATH (existing, unchanged)
  |      \-- Stage 3: reduce (claude --print) -> dream-report.md
  |
  +-- if N >= 130K tokens: MAP-REDUCE PATH (NEW)
         |
         +-- Stage 3a: chunker.py
         |      \-- $TMP/chunks/chunk-{1..N}.md (greedy token-bucketed, ~150K each)
         |      \-- Fails up-front if any chunk would exceed 180K
         |
         +-- Stage 3b: parallel map calls (bash & + wait)
         |      \-- claude --print --model claude-haiku-4-5-20251001
         |               --bare --no-session-persistence
         |               --system-prompt-file prompts/map-system.md
         |               --output-format json
         |          (prompt piped via stdin; not CLI argument)
         |      \-- $TMP/extracts/extract-{1..N}.md
         |
         +-- Stage 3c: concatenate extracts (chronological)
         |      \-- $TMP/extracts-concat.md with "=== CHUNK k (date_range) ===" separators
         |
         +-- Stage 3d: reduce call (Sonnet)
         |      \-- claude --print --model claude-sonnet-4-6
         |               --append-system-prompt prompts/system.md
         |               --mcp-config ...  (MCPs ACTIVE for this call only)
         |          reconcile.md template, {SESSIONS} = extracts-concat
         |      \-- dream-report.md (same format as today)
         |
         +-- Stage 4: save + log + stamp .last-run
                \-- $OUTPUT_DIR/dream-<date>.md         (existing)
                \-- $OUTPUT_DIR/dream-extracts-<date>/  (NEW, gitignored)
                \-- $OUTPUT_DIR/dream-errors-<date>/    (NEW, only on failure, gitignored)
                \-- $SKILL_DIR/.usage-log.jsonl extended with schema_version=2 + chunk fields
                \-- $SKILL_DIR/.last-run stamp
```

Key invariants:

- `apply_auto.py` and `apply_undo.sh` are untouched; the reduce step still produces today's dream-report format.
- **MCP tools (Notion, Calendar, Gmail) are active ONLY in the reduce call.** Map calls pass `--bare --no-session-persistence` to prevent reading CLAUDE.md, plugin context, or writing new JSONLs to `~/.claude/projects/` (which would feed back into the next dream cycle's preprocess.py).
- **Different models per stage:** Haiku 4.5 for map (cheap, fast, sufficient for extraction); Sonnet 4.6 for reduce (consistency with current behavior + handles complex synthesis).
- **Strict abort:** any non-zero exit code or any response with `is_error: true` (even with exit 0) kills the script. No partial outputs are written to the output directory other than preserved error logs.
- **Single-call path preserved verbatim** for windows below threshold so quota is not wasted.
- **Empty-vault first-run** also routes to single-call path regardless of token count.

## Components

### dream.sh (modified)

**Role:** orchestrator.
**Changes:**
- After Stages 1-2, invoke `count_tokens.py` on the combined size (`sessions.md` + `vault.md` + ~10K prompt overhead).
- If under 130K tokens AND vault is non-empty, take the existing single-call path.
- If at or above 130K tokens, run the chunked path (Stages 3a-3d).
- Route to single-call path if `vault.md < 1KB` (empty-vault first-run) regardless of token count.
- Rewrite the EXIT trap as a single function that runs unconditionally on EXIT:

  ```bash
  on_exit() {
    local rc=$?
    if [[ "$rc" != "0" && -d "$TMP/responses" ]]; then
      mkdir -p "$OUTPUT_DIR/dream-errors-$DATE" || true
      cp "$TMP/responses/"*.log "$OUTPUT_DIR/dream-errors-$DATE/" 2>/dev/null || true
    fi
    rm -rf "$TMP"
    exit $rc
  }
  trap on_exit EXIT
  ```

- Extend `.usage-log.jsonl` row with `schema_version: 2`, `chunked: bool`, `chunk_count: N`, `map_token_totals: {input, output, cache_read, cache_creation}`, `reduce_token_totals: {...}`, `map_call_metrics: [{chunk_id, wall_time_ms, extract_bytes, stop_reason, model}]`, `tiktoken_used: bool`.
- Add `--force-chunked` flag (force map-reduce path even below threshold; for testing).
- Add `--force-single` flag (force single-call path even above threshold). When set, also pass `--max-budget-usd 2.00` to the underlying `claude --print` call as a safety cap against quota overruns (default 2 USD, override via `DREAM_MAX_BUDGET_USD` env).
- Add `--map-model` flag override (default `claude-haiku-4-5-20251001`).
- Map call prompt construction pipes the prompt text via **stdin**, not as a CLI argument. macOS `ARG_MAX` is ~1MB and a 150K-token chunk approaches 600KB; CLI arg passing is unsafe. Pattern:

  ```bash
  printf '%s' "$MAP_PROMPT" | claude --print ... 2> "$TMP/responses/error-$k.log" > "$TMP/responses/response-$k.json"
  ```

- After each `wait $pid`, both check the exit code AND parse the JSON for `is_error: true` and `stop_reason in {max_tokens, refusal}`. Any of these means failure.

### scripts/chunker.py (NEW)

**Role:** split `sessions.md` into chunk files using greedy token-bucketing.
**Input:** `--input sessions.md --output-dir $TMP/chunks/ --target-tokens 150000 [--min 2] [--max 8] [--hard-max 180000]`
**Output:** `chunk-1.md` through `chunk-N.md` (chronological order), plus a `chunks-meta.json` summary; prints chunk count + per-chunk date ranges + token counts to stdout.
**Algorithm:**
1. Parse session-header lines from sessions.md (`--- <source> YYYY-MM-DD HH:MM ---`); collect each complete session block (header + body until next header or EOF) with its start timestamp.
2. Sort blocks chronologically.
3. **Greedy bucketing**: accumulate blocks into the current chunk until adding the next block would push it over `target_tokens` (150K). Close that chunk, start a new one. Repeat.
4. If the resulting chunk count is below `min` (e.g. one large session forms one big chunk and the remainder forms a tiny second chunk, or total below target), redistribute proportionally to satisfy min.
5. If the resulting chunk count exceeds `max`, merge the smallest adjacent pair repeatedly until count ≤ max.
6. After redistribution, if **any chunk exceeds `hard-max` (180K)**, exit with a clear error message ("window too large for chunked mode; narrow --since or wait for the next release"). Do not proceed.
7. Write each chunk to `chunk-{i}.md` (1-indexed, chronological); write `chunks-meta.json` with `[{chunk_id, start, end, token_count, session_count}, ...]`.
**Depends on:** `count_tokens.py` (importable).

### scripts/count_tokens.py (NEW)

**Role:** count tokens in a file or stdin.
**Input:** path argument or `-` for stdin.
**Output:** single integer to stdout.
**Strategy:**
- Try `import tiktoken; enc = tiktoken.get_encoding("cl100k_base")`; use `len(enc.encode(text))`.
- On ImportError, fall back to `int(len(text) / 3.5)`; warn once to stderr.
- Expose `count_tokens(text: str) -> tuple[int, bool]` returning (count, used_tiktoken). dream.sh logs the bool into `.usage-log.jsonl`.

### prompts/map.md (NEW)

User-message template for map calls. Placeholders: `{TODAY}`, `{CHUNK_RANGE}`, `{CHUNK_CONTENT}`.

```markdown
Extract persona signals from the following local-conversation transcript chunk.

Today's date: {TODAY}
Chunk date range: {CHUNK_RANGE}

=== TRANSCRIPT ===
{CHUNK_CONTENT}

Produce extraction output per your system prompt. Preserve verbatim source
session references in every bullet so downstream channel-triangulation works.
```

### prompts/map-system.md (NEW)

System prompt for map calls. Defines what counts as a persona signal, loose-markdown output format, hard rules, and the citation requirement that downstream `apply_auto.py` parsing depends on.

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

## Citation requirement (CRITICAL)

Every bullet MUST end with a citation that names the source session
verbatim from the chunk's session-header lines.

The chunk you're reading contains session blocks delimited like:
    --- claude 2026-05-19 13:24 ---
    USER: ...

Cite using this exact format: `(Claude Session 2026-05-19 13:24)` or
`(Codex Session 2026-05-19 13:24)` depending on which source the
session came from. Downstream tooling parses these prefixes to count
distinct evidence channels — do not paraphrase or omit them.

Example bullet:
- Bohdan switched from React to Svelte for the frontend rebuild. (Claude Session 2026-05-21 09:14)

## Hard rules

- NO YAML frontmatter
- NO dream-report sections (no "## Auto-apply", "## Needs confirmation", etc.)
- NO recommendations or proposals — extraction only
- NO MCP tool use (you don't have those tools here)
- If chunk has zero persona signal: output the single line "No persona-relevant signals in this chunk."
- Target output: under 2KB per chunk
```

### prompts/reconcile.md (modified)

Existing template gets a paragraph added after the `=== CONVERSATION SIGNALS ===` block:

```
Note: when the conversation window is large, this CONVERSATION SIGNALS block
contains per-chunk PRE-EXTRACTED signal lists rather than raw conversation
transcripts, delimited by `=== CHUNK N (date_range) ===` markers. Treat them
as already-filtered persona signal lists.

Each extracted bullet already includes a verbatim source citation in the form
`(Claude Session YYYY-MM-DD HH:MM)` or `(Codex Session YYYY-MM-DD HH:MM)`.
When you write proposals into the dream report, you MUST preserve these
citations VERBATIM in the proposal's Evidence: block — the downstream parser
counts distinct channels by matching this exact prefix format. Do not
paraphrase ("during a coding session") — copy the literal prefix.

The `{WINDOW}` value above always refers to the FULL conversation window, not
to any individual chunk's date range. Use it as such when phrasing dates and
relative-time expressions.
```

### prompts/system.md (modified)

Add one paragraph explaining the dual-path architecture:

```
This reconcile call may be running in one of two modes:

1. **Single-call mode** — the CONVERSATION SIGNALS block contains raw cleaned
   transcripts from preprocess.py. Treat them as primary evidence; cite each
   message by its session header (`Claude Session YYYY-MM-DD HH:MM`).

2. **Chunked mode** — the CONVERSATION SIGNALS block contains per-chunk
   pre-extracted signal summaries (with `## State changes`, `## Decisions`,
   etc. headers and `=== CHUNK N ===` separators). Each bullet already has
   a verbatim source citation embedded. Treat the bullets as filtered
   evidence; copy the embedded citations verbatim into your proposals.

In both modes, MCP-tool probes (Notion / Calendar / Gmail / Filesystem) are
your responsibility and run as today. The map step does NOT touch MCPs.
```

### Output artifacts (NEW)

- `$OUTPUT_DIR/dream-extracts-<date>/chunk-{1..N}.md` — preserved map outputs, gitignored, for audit + prompt tuning.
- `$OUTPUT_DIR/dream-extracts-<date>/chunks-meta.json` — chunker metadata.
- `$OUTPUT_DIR/dream-errors-<date>/error-{N}.log` — preserved stderr from any failed chunk, only written on non-zero exit.

## Data flow (chunked path)

1. `preprocess.py` writes `$TMP/sessions.md`.
2. `load_vault_state.py` writes `$TMP/vault.md`.
3. `count_tokens.py` reports `N_sessions`. dream.sh computes total LLM call size as `N_sessions + N_vault + 10000` (prompt overhead).
4. **Route:** if `vault.md < 1KB` OR `total < 130K tokens`, single-call path. Else chunked path.
5. `chunker.py` writes `$TMP/chunks/chunk-{1..K}.md` (chronological, greedy token-bucketed). If any chunk would exceed 180K, exit with error before any LLM call.
6. For each chunk `k`:
   - Substitute `{TODAY}`, `{CHUNK_RANGE}` (from `chunks-meta.json`), `{CHUNK_CONTENT}` into `prompts/map.md`.
   - Launch in background:
     ```bash
     printf '%s' "$MAP_PROMPT" | \
       timeout 600 claude --print --output-format json \
         --model claude-haiku-4-5-20251001 \
         --bare \
         --no-session-persistence \
         --system-prompt-file "$PROMPTS_DIR/map-system.md" \
         --permission-mode bypassPermissions \
         > "$TMP/responses/response-$k.json" 2> "$TMP/responses/error-$k.log" &
     MAP_PIDS+=($!)
     ```
   - Optional 1-second stagger between launches to reduce keychain / plugin-init contention.
7. `wait` each PID. For each response JSON: check non-zero exit, OR `is_error: true`, OR `stop_reason` in `{max_tokens, refusal}`. Any of these → exit 1 with chunk-N identifier in the error message.
8. For each successful response, extract `result` field, validate non-empty, write `$TMP/extracts/extract-{k}.md`.
9. Concatenate extracts in chronological order with separators:
   ```
   === CHUNK 1 (2026-04-26 → 2026-04-30) ===
   [extract-1.md content]

   === CHUNK 2 (2026-04-30 → 2026-05-04) ===
   [extract-2.md content]
   ...
   ```
   → `$TMP/extracts-concat.md`.
10. Build reduce prompt: substitute `{TODAY}`, `{WINDOW}` (full original window), `{SESSIONS}` (concat extracts), `{VAULT}` into `prompts/reconcile.md`.
11. Run reduce call (Sonnet 4.6, MCPs active, full reconcile system.md): output → `$TMP/response.json`.
12. Parse response (existing logic: strip preamble, extract result, atomic write to `$OUTPUT_DIR/dream-<date>.md`).
13. Copy `$TMP/extracts/*.md` + `chunks-meta.json` to `$OUTPUT_DIR/dream-extracts-<date>/`.
14. Append v2-schema row to `.usage-log.jsonl`.
15. Stamp `.last-run`.

## Error handling

Strict abort policy: any failure kills the script. User reruns.

| Failure | Detection | Behavior |
|---|---|---|
| preprocess / chunker / count-tokens failure | exit code != 0 | set -e kills dream.sh |
| Chunker detects per-chunk > 180K | chunker explicit exit | dream.sh exits with hint to narrow --since |
| Map call non-zero exit | `wait $pid` | exit 1 with chunk identifier |
| Map call exit 0 but `is_error: true` in response JSON | post-wait JSON check | exit 1 with chunk identifier + error text |
| Map call `stop_reason: max_tokens` | post-wait JSON check | exit 1 (extract is truncated, unreliable) |
| Map call empty `result` | file-size check | treated as failure |
| Map call hangs | `timeout 600` wrapper | killed at 600s, exit 124 |
| Reduce step fails (any of the above) | same as above | exit 1, $TMP cleaned, error logs preserved |
| MCP server errors during reduce | LLM handles per existing system.md | Note absence, continue |

On any non-zero exit, the EXIT trap copies `$TMP/responses/error-*.log` to `$OUTPUT_DIR/dream-errors-<date>/` before cleaning `$TMP`. Successful runs do not write this directory.

## Edge cases

| Case | Handling |
|---|---|
| Empty `sessions.md` (last-run was minutes ago) | tokens=0 → single-call path → trivial reduce |
| Empty `vault.md` (fresh install, < 1KB) | single-call path regardless of token count |
| Threshold edge (130-150K tokens) | chunker `min=2` splits into 2 chunks |
| Very large window (per-chunk > 180K after clamp=8) | chunker exits up-front with clear error; no quota burned |
| tiktoken not installed | fallback to bytes/3.5 estimate, warn once, log `tiktoken_used: false` |
| `--force-chunked` with 50K tokens | chunker creates 2 chunks ~25K each |
| `--force-single` with 500K tokens | claude rejects; `--max-budget-usd` cap limits damage |
| Map LLM returns frontmatter or refuses (no `is_error` flag) | reduce receives malformed extract; quality degrades but doesn't crash; spot-check via extracts dir |
| One chunk has no persona signal | extract is the placeholder line; reduce treats as "no signal in that period" |
| Concurrent dream.sh runs | out of scope (race on `.last-run` and output) |
| `--apply` short-path | unchanged, doesn't touch new code |

## Observability

`.usage-log.jsonl` row schema v2 (back-compat: old rows lack these keys; consumers must handle absence):

```json
{
  "schema_version": 2,
  "ts": "2026-05-26T...",
  "date": "2026-05-26",
  "model": "claude-sonnet-4-6",        // reduce model
  "map_model": "claude-haiku-4-5-20251001",
  "window": "30d",
  "chunked": true,
  "chunk_count": 6,
  "tiktoken_used": true,
  "input_tokens": ...,                  // reduce-step uncached input
  "output_tokens": ...,
  "cache_read_input_tokens": ...,
  "cache_creation_input_tokens": ...,
  "cost_usd": ...,
  "duration_ms": ...,
  "report_bytes": ...,
  "map_token_totals": {
    "input_tokens": ...,
    "output_tokens": ...,
    "cache_read_input_tokens": ...,
    "cache_creation_input_tokens": ...
  },
  "reduce_token_totals": { /* same fields as above */ },
  "map_call_metrics": [
    {
      "chunk_id": 1,
      "wall_time_ms": 124000,
      "input_tokens": ...,
      "output_tokens": ...,
      "extract_bytes": 1850,
      "stop_reason": "end_turn",
      "model": "claude-haiku-4-5-20251001"
    },
    ...
  ]
}
```

The `map_call_metrics[*].extract_bytes` field is the prompt-tuning signal: if many chunks emit <500 bytes the map prompt is over-filtering; if many emit >3KB it's under-filtering.

Additional stderr output from dream.sh:
- chunker.py prints chunk count + date ranges to stdout
- dream.sh prints `[3a/4]` chunking, `[3b/4]` running K parallel map calls, `[3c/4]` concatenate, `[3d/4]` reduce
- Map call results preserved in `$OUTPUT_DIR/dream-extracts-<date>/`
- Error logs preserved on failure in `$OUTPUT_DIR/dream-errors-<date>/`

## Cost / quota expectations

Per chunked run:
- N map calls × Haiku (claude-haiku-4-5-20251001): cheap, no cache reuse across chunks (each is unique input).
- 1 reduce call × Sonnet 4.6: similar size to today's single-call but extracts (~16KB) instead of raw sessions (~1MB).

Naive estimate: 5-8× input-token volume vs today's single-call (mostly Haiku tokens), but Haiku rate is ~10× cheaper per token. Net cost should be **comparable or slightly higher** than today's run; the cost story will be validated by the v2 `.usage-log.jsonl` instrumentation.

**Known limitation:** prompt caching is not addressable via `claude --print` (SDK-only feature). Cross-chunk cache reuse is not possible in the current architecture. Document as accepted limitation; cost story would improve significantly if/when CLI exposes cache markers.

## Testing strategy

### Deterministic (no LLM)

- `chunker.py` unit test: synthetic sessions.md with N session headers spanning T days, assert (a) expected chunk count, (b) chunks are chronologically ordered, (c) min/max enforcement, (d) up-front fail when any chunk would exceed hard-max.
- `count_tokens.py` parity test: sample file via tiktoken vs bytes-fallback within ~15%.
- dream.sh routing dry-run: mock `claude` as `cat`; verify correct route at 130K boundary AND empty-vault override.
- Bash background-process integration: mock `claude` as a script that emits `{"is_error": true}` with exit 0; verify dream.sh detects the failure and exits 1.
- Bash EXIT-trap integration: inject a failure, verify error logs land in `dream-errors-<date>/` and `$TMP` is cleaned.

### LLM-dependent smoke checks (manual)

- `--force-chunked` on a 7d window: produces dream report structurally identical to single-call output; extracts dir contains N files; each bullet in extracts has citation prefix.
- Real 30d window run: completes without abort; wall time <10 min; spot-check dream report citations parse correctly under `apply_auto.py --dry-run`.
- `--force-single` regression on 7d.
- Map extract spot-check: confirm sections populated, no frontmatter, target <2KB, every bullet ends with `(Claude Session ...)` or `(Codex Session ...)`.
- `apply_auto.py` channel-count regression: ensure first chunked report's proposals still classify into `## Auto-apply` (≥2 channels) vs `## Needs confirmation` (1 channel) per existing parser.

### Iteration

The map prompt is the most likely thing needing tuning. First 2-3 chunked runs:

1. Open extracts, read each `chunk-N.md`.
2. Read corresponding dream report.
3. Identify signals that ENTERED dream report from extracts (map worked).
4. Identify signals present in raw sessions but ABSENT from dream report (map missed).
5. Verify citation prefixes pass through map and into final report.
6. Tune map prompt. Prefer false positives (keep borderline) over false negatives (drop persona signal).

## Migration / backward compatibility

- `.last-run`, dream-report.md format: unchanged.
- `.usage-log.jsonl`: schema v2 with `schema_version` field. Old rows have no version field (implicitly v1).
- `apply_auto.py`, `apply_undo.sh`: unchanged.
- Existing single-call path preserved verbatim for windows below threshold.
- `.gitignore` updated to add `dream-extracts-*/`, `dream-errors-*/` patterns.
- New files are additive.
- `--apply` short-path unchanged.

No migration script needed.

## Out of scope (deferred)

- Resume from partial map failure
- Auto-retry on transient failures
- Map prompt as TOML/JSON config
- Token-budget alerting beyond `--max-budget-usd` safety cap
- Sequential fallback if parallel collides with rate limits
- Prompt caching across map calls (CLI doesn't expose cache markers)
- Cross-cycle extract reuse (next cycle's preprocess starts fresh)

## File summary

### New files (5)
- `scripts/chunker.py`
- `scripts/count_tokens.py`
- `prompts/map.md`
- `prompts/map-system.md`
- (output artifacts at runtime: `dream-extracts-<date>/`, `dream-errors-<date>/`)

### Modified files (4)
- `dream.sh`
- `prompts/reconcile.md`
- `prompts/system.md`
- `.gitignore`

### Unchanged files
- `scripts/preprocess.py`
- `scripts/load_vault_state.py`
- `scripts/apply_auto.py`
- `scripts/apply_undo.sh`
- `setup.sh`, `doctor.sh`
- `SKILL.md` (optional one-line addition about chunked mode)
- `config/*` (no schema changes)
