#!/usr/bin/env bash
# dream.sh — entry point for the dream-skill reconciliation cycle.
#
# Pipeline (4 stages, only stage 3 calls the LLM):
#   1. preprocess.py        → cleaned conversation transcript (no LLM)
#   2. load_vault_state.py  → vault snapshot                (no LLM)
#   3. claude --mcp-config  → dream report                  (LLM, isolated MCPs)
#   4. apply_auto.py        → dry-run summary of proposals  (no LLM at this stage)
#
# MCP isolation: this script invokes Claude with `--mcp-config` + `--strict-mcp-config`
# pointing to the skill's own config. Interactive Claude sessions outside this
# script are unaffected — no Notion / Calendar / Gmail / etc. servers leak into
# daily contexts.

set -euo pipefail

# ============================================================
# Skill-dir discovery (portable, works for plugins + symlinks)
# ============================================================

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
PROMPTS_DIR="$SKILL_DIR/prompts"
CONFIG_DIR="$SKILL_DIR/config"

# ============================================================
# PATH boost for cron / minimal shells.
# MCP servers in mcp-config.json are launched via `npx -y ...`,
# so node/npx must be discoverable.
# ============================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# ============================================================
# Defaults (lowest priority — overridden by env, then CLI flags)
# ============================================================

DEFAULT_VAULT_ROOT="$HOME/Documents/Obsidian"
DEFAULT_CLAUDE_SESSIONS_ROOT="$HOME/.claude/projects"
DEFAULT_CODEX_SESSIONS_ROOT="$HOME/.codex/sessions"
DEFAULT_CONVERSATION_SOURCES="claude,codex"
DEFAULT_MODEL="claude-sonnet-4-6"
# DEFAULT_SINCE is intentionally unset: when SINCE is empty, preprocess.py
# resolves the cutoff from <skill>/.last-run with a 30d cap fallback.

# ============================================================
# Resolve from env (priority 2 — overridden only by CLI flags)
# ============================================================

VAULT_ROOT="${DREAM_VAULT_ROOT:-$DEFAULT_VAULT_ROOT}"
OUTPUT_DIR="${DREAM_OUTPUT_DIR:-}"
CLAUDE_SESSIONS_ROOT="${DREAM_CLAUDE_SESSIONS_ROOT:-${DREAM_SESSIONS_ROOT:-$DEFAULT_CLAUDE_SESSIONS_ROOT}}"
CODEX_SESSIONS_ROOT="${DREAM_CODEX_SESSIONS_ROOT:-$DEFAULT_CODEX_SESSIONS_ROOT}"
CONVERSATION_SOURCES="${DREAM_CONVERSATION_SOURCES:-$DEFAULT_CONVERSATION_SOURCES}"
MODEL="${DREAM_MODEL:-$DEFAULT_MODEL}"
SINCE="${DREAM_SINCE:-}"
MCP_CONFIG=""
NO_MCP="${DREAM_NO_MCP:-0}"
APPLY=0
DRY_RUN=1   # default behavior: produce a report, do not apply
VERBOSE=0

# ============================================================
# CLI arg parsing (priority 1)
# ============================================================

print_help() {
  cat <<EOF
Usage: dream.sh [options]

Configuration (highest priority first: CLI flag > env > config > default):

  --vault-root PATH       Obsidian vault root.
                          env: DREAM_VAULT_ROOT
                          default: \$HOME/Documents/Obsidian

  --output-dir PATH       Where dream reports are written.
                          env: DREAM_OUTPUT_DIR
                          default: <vault-root>/dream-reports

  --sources LIST          Conversation sources to scan: claude,codex,all.
                          env: DREAM_CONVERSATION_SOURCES
                          default: claude,codex

  --sessions-root PATH    Claude Code session JSONL root. Backward-compatible
                          alias for --claude-sessions-root.
                          env: DREAM_SESSIONS_ROOT
                          default: \$HOME/.claude/projects

  --claude-sessions-root PATH
                          Claude Code session JSONL root.
                          env: DREAM_CLAUDE_SESSIONS_ROOT
                          default: \$HOME/.claude/projects

  --codex-sessions-root PATH
                          Codex CLI local session JSONL root.
                          env: DREAM_CODEX_SESSIONS_ROOT
                          default: \$HOME/.codex/sessions

  --model ID              Model used in stage 3 reconciliation.
                          env: DREAM_MODEL
                          default: claude-sonnet-4-6

  --since WINDOW          Session lookback (e.g. 7d, 14d, 24h).
                          env: DREAM_SINCE
                          default: auto (resumes from <skill>/.last-run; 30d cap)

  --mcp-config PATH       Custom MCP config JSON.
                          default: <skill>/config/mcp-config.json (or .example.json)

  --no-mcp                Skip MCP probes entirely (Tier 0 only: sessions + vault).

  --dry-run               (Default.) Produce a report; do not apply.

  --apply                 After review: invoke apply_auto.py --apply on the latest report.

  --verbose               Print token cost summary at end.

  --help, -h              Show this message.

Output:
  <output-dir>/dream-\$(date -u +%F).md

Examples:
  ./dream.sh                                # standard run
  ./dream.sh --since 14d --verbose          # wider window, show costs
  ./dream.sh --sources claude               # Claude conversations only
  ./dream.sh --sources codex                # Codex conversations only
  ./dream.sh --no-mcp                       # Tier 0 only
  ./dream.sh --vault-root /tmp/test-vault   # different vault
  ./dream.sh --apply                        # apply latest report (after manual review)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-root)    VAULT_ROOT="$2"; shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
    --sources)       CONVERSATION_SOURCES="$2"; shift 2 ;;
    --sessions-root) CLAUDE_SESSIONS_ROOT="$2"; shift 2 ;;
    --claude-sessions-root) CLAUDE_SESSIONS_ROOT="$2"; shift 2 ;;
    --codex-sessions-root) CODEX_SESSIONS_ROOT="$2"; shift 2 ;;
    --model)         MODEL="$2"; shift 2 ;;
    --since)         SINCE="$2"; shift 2 ;;
    --mcp-config)    MCP_CONFIG="$2"; shift 2 ;;
    --no-mcp)        NO_MCP=1; shift ;;
    --dry-run)       DRY_RUN=1; APPLY=0; shift ;;
    --apply)         APPLY=1; DRY_RUN=0; shift ;;
    --verbose)       VERBOSE=1; shift ;;
    --help|-h)       print_help; exit 0 ;;
    *) echo "dream.sh: unknown arg: $1" >&2; echo "Try --help" >&2; exit 1 ;;
  esac
done

# Derive defaults that depend on resolved values
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$VAULT_ROOT/dream-reports"
fi

# Resolve MCP config path (after CLI parse so it can override)
if [[ -z "$MCP_CONFIG" ]]; then
  if [[ -f "$CONFIG_DIR/mcp-config.json" ]]; then
    MCP_CONFIG="$CONFIG_DIR/mcp-config.json"
  elif [[ -f "$CONFIG_DIR/mcp-config.example.json" ]]; then
    MCP_CONFIG="$CONFIG_DIR/mcp-config.example.json"
    if [[ "$NO_MCP" != "1" ]]; then
      echo "dream.sh: WARN  no mcp-config.json found; falling back to .example.json." >&2
      echo "             tokens in the example are placeholders — MCP probes will likely fail." >&2
      echo "             run ./setup.sh to configure properly, or pass --no-mcp." >&2
    fi
  fi
fi

# ============================================================
# Sanity checks
# ============================================================

if [[ ! -d "$VAULT_ROOT" ]]; then
  echo "dream.sh: ERROR  vault root not found: $VAULT_ROOT" >&2
  echo "             pass --vault-root PATH or set DREAM_VAULT_ROOT, then re-run." >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "dream.sh: ERROR  'claude' CLI not on PATH." >&2
  echo "             install via https://docs.claude.com/claude-code" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "dream.sh: ERROR  python3 not on PATH (need 3.11+)." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ============================================================
# Per-cycle temp dir
# ============================================================

TMP="$(mktemp -d)"

# Custom EXIT handler: on non-zero exit, preserve worker error logs.
# Robust to early exits where DATE/OUTPUT_DIR may not yet be set.
on_exit() {
  local rc=$?
  local out_dir="${OUTPUT_DIR:-}"
  local date_stamp="${DATE:-$(date -u '+%Y-%m-%d')}"
  if [[ "$rc" != "0" && -d "${TMP:-}/responses" && -n "$out_dir" ]]; then
    mkdir -p "$out_dir/dream-errors-$date_stamp" 2>/dev/null || true
    cp "$TMP/responses/"*.log "$out_dir/dream-errors-$date_stamp/" 2>/dev/null || true
  fi
  rm -rf "${TMP:-/nonexistent-fallback-no-rm}"
  exit "$rc"
}
trap on_exit EXIT

DATE="$(date -u '+%Y-%m-%d')"
OUTPUT_REPORT="$OUTPUT_DIR/dream-$DATE.md"
LAST_RUN_FILE="$SKILL_DIR/.last-run"

# Human-readable label for banner + reconcile prompt
if [[ -n "$SINCE" ]]; then
  WINDOW_LABEL="$SINCE"
elif [[ -f "$LAST_RUN_FILE" ]]; then
  WINDOW_LABEL="since last run ($(<"$LAST_RUN_FILE"))"
else
  WINDOW_LABEL="auto (no prior run, 30d cap)"
fi

echo "==============================================="
echo "  dream-skill cycle — $DATE"
echo "==============================================="
echo "  vault:    $VAULT_ROOT"
echo "  output:   $OUTPUT_REPORT"
echo "  sources:  $CONVERSATION_SOURCES"
echo "  claude:   $CLAUDE_SESSIONS_ROOT"
echo "  codex:    $CODEX_SESSIONS_ROOT"
echo "  window:   $WINDOW_LABEL"
echo "  model:    $MODEL"
if [[ "$NO_MCP" == "1" ]]; then
  echo "  mcp:      (skipped via --no-mcp)"
elif [[ -n "$MCP_CONFIG" ]]; then
  echo "  mcp:      $MCP_CONFIG"
else
  echo "  mcp:      (none — no config found)"
fi
echo ""

# ============================================================
# Apply-only short path
# ============================================================
# If --apply was passed and a report for today already exists, hand off to
# apply_auto.py and exit. (We never auto-apply mid-cycle; apply is always
# its own user-driven step.)

if [[ "$APPLY" == "1" ]]; then
  if [[ ! -f "$OUTPUT_REPORT" ]]; then
    echo "dream.sh: ERROR  --apply requested but report not found: $OUTPUT_REPORT" >&2
    echo "             run dream.sh without --apply first, review the report, then --apply." >&2
    exit 1
  fi
  echo "[apply] running apply_auto.py against $OUTPUT_REPORT"
  ROLLBACK_DIR="$VAULT_ROOT/.dream-rollback"
  mkdir -p "$ROLLBACK_DIR"
  python3 "$SCRIPTS_DIR/apply_auto.py" \
    --vault-root "$VAULT_ROOT" \
    --report     "$OUTPUT_REPORT" \
    --rollback-dir "$ROLLBACK_DIR" \
    --model      "$MODEL" \
    --apply
  exit $?
fi

# ============================================================
# Stage 1: preprocess local conversation JSONLs (no LLM)
# ============================================================

echo "[1/4] preprocess conversations…"
PREPROCESS_ARGS=(
  --sources "$CONVERSATION_SOURCES"
  --claude-sessions-root "$CLAUDE_SESSIONS_ROOT"
  --codex-sessions-root "$CODEX_SESSIONS_ROOT"
  --output "$TMP/sessions.md"
)
if [[ -n "$SINCE" ]]; then
  PREPROCESS_ARGS+=(--since "$SINCE")
fi
python3 "$SCRIPTS_DIR/preprocess.py" "${PREPROCESS_ARGS[@]}"
SESSIONS_BYTES=$(wc -c < "$TMP/sessions.md" | tr -d ' ')
USER_MSG_COUNT=$(grep -c "^USER:" "$TMP/sessions.md" 2>/dev/null || echo 0)
SESSIONS_TOKENS=$(python3 "$SCRIPTS_DIR/count_tokens.py" "$TMP/sessions.md")
echo "      conversations.md: ${SESSIONS_BYTES} bytes, ${USER_MSG_COUNT} user messages, ~${SESSIONS_TOKENS} tokens"

# ============================================================
# Stage 2: snapshot vault state (no LLM)
# ============================================================

echo "[2/4] snapshot vault state…"
LOAD_ARGS=(--vault-root "$VAULT_ROOT" --output "$TMP/vault.md")
if [[ -f "$CONFIG_DIR/vault-paths.toml" ]]; then
  LOAD_ARGS+=(--config "$CONFIG_DIR/vault-paths.toml")
fi
python3 "$SCRIPTS_DIR/load_vault_state.py" "${LOAD_ARGS[@]}"
VAULT_BYTES=$(wc -c < "$TMP/vault.md" | tr -d ' ')
echo "      vault.md: ${VAULT_BYTES} bytes"

# ============================================================
# Stage 2.5: route decision (single-call vs chunked map-reduce)
# ============================================================

ROUTE_THRESHOLD_TOKENS="${DREAM_ROUTE_THRESHOLD:-130000}"
VAULT_BYTES_NUM=$(wc -c < "$TMP/vault.md" | tr -d ' ')
VAULT_TOKENS=$(python3 "$SCRIPTS_DIR/count_tokens.py" "$TMP/vault.md")
# 10000 token overhead for prompt template + system prompt
PROMPT_OVERHEAD=10000
TOTAL_TOKENS=$((SESSIONS_TOKENS + VAULT_TOKENS + PROMPT_OVERHEAD))

# Empty-vault first-run always single-call
if [[ "$VAULT_BYTES_NUM" -lt 1024 ]]; then
  ROUTE=single
  ROUTE_REASON="empty vault (${VAULT_BYTES_NUM} bytes < 1KB)"
elif [[ "${FORCE_CHUNKED:-0}" == "1" ]]; then
  ROUTE=chunked
  ROUTE_REASON="--force-chunked"
elif [[ "${FORCE_SINGLE:-0}" == "1" ]]; then
  ROUTE=single
  ROUTE_REASON="--force-single"
elif [[ "$TOTAL_TOKENS" -lt "$ROUTE_THRESHOLD_TOKENS" ]]; then
  ROUTE=single
  ROUTE_REASON="total ${TOTAL_TOKENS} tokens < threshold ${ROUTE_THRESHOLD_TOKENS}"
else
  ROUTE=chunked
  ROUTE_REASON="total ${TOTAL_TOKENS} tokens >= threshold ${ROUTE_THRESHOLD_TOKENS}"
fi

echo "      route: $ROUTE ($ROUTE_REASON)"

# ============================================================
# Stage 3: reconcile via Claude (the only paid step)
# ============================================================

if [[ "$DRY_RUN" == "1" ]] && [[ "${DREAM_SKIP_LLM:-0}" == "1" ]]; then
  echo "[3/4] DRY RUN (DREAM_SKIP_LLM=1) — skipping LLM call."
  cp "$TMP/sessions.md" "/tmp/dream-sessions-$DATE.md"
  cp "$TMP/vault.md"    "/tmp/dream-vault-$DATE.md"
  echo "      inputs preserved at /tmp/dream-{sessions,vault}-$DATE.md"
  exit 0
fi

if [[ "$ROUTE" == "single" ]]; then

  echo "[3/4] reconcile via Claude ($MODEL)…"

  if [[ ! -f "$PROMPTS_DIR/reconcile.md" ]]; then
    echo "dream.sh: ERROR  reconcile prompt missing: $PROMPTS_DIR/reconcile.md" >&2
    exit 1
  fi

  RECONCILE_TEMPLATE="$(cat "$PROMPTS_DIR/reconcile.md")"
  SESSIONS_CONTENT="$(cat "$TMP/sessions.md")"
  VAULT_CONTENT="$(cat "$TMP/vault.md")"

  # Safe substitution via Python (avoids shell escaping hell on user content)
  PROMPT="$(WINDOW="$WINDOW_LABEL" \
             TODAY="$DATE" \
             SESSIONS="$SESSIONS_CONTENT" \
             VAULT="$VAULT_CONTENT" \
             TEMPLATE="$RECONCILE_TEMPLATE" \
           python3 -c '
import os
t = os.environ["TEMPLATE"]
t = t.replace("{TODAY}",   os.environ["TODAY"])
t = t.replace("{WINDOW}",  os.environ["WINDOW"])
t = t.replace("{SESSIONS}", os.environ["SESSIONS"])
t = t.replace("{VAULT}",    os.environ["VAULT"])
print(t, end="")
')"

  SYSTEM_PROMPT=""
  if [[ -f "$PROMPTS_DIR/system.md" ]]; then
    SYSTEM_PROMPT="$(cat "$PROMPTS_DIR/system.md")"
  fi

  RESPONSE_JSON="$TMP/response.json"
  USAGE_LOG="$SKILL_DIR/.usage-log.jsonl"

  CLAUDE_ARGS=(
    --model "$MODEL"
    --print
    --output-format json
    --tools ""
    --permission-mode bypassPermissions
  )

  if [[ "$NO_MCP" != "1" ]] && [[ -n "$MCP_CONFIG" ]] && [[ -f "$MCP_CONFIG" ]]; then
    CLAUDE_ARGS+=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
  fi

  if [[ -n "$SYSTEM_PROMPT" ]]; then
    CLAUDE_ARGS+=(--append-system-prompt "$SYSTEM_PROMPT")
  fi

  claude "${CLAUDE_ARGS[@]}" "$PROMPT" > "$RESPONSE_JSON"

  if [[ ! -s "$RESPONSE_JSON" ]]; then
    echo "dream.sh: ERROR  claude returned empty response" >&2
    exit 1
  fi

else
  # ============================================================
  # Stage 3a: chunker
  # ============================================================
  echo "[3a/4] chunker — splitting sessions.md…"
  mkdir -p "$TMP/chunks" "$TMP/responses" "$TMP/extracts"
  python3 "$SCRIPTS_DIR/chunker.py" \
    --input "$TMP/sessions.md" \
    --output-dir "$TMP/chunks" \
    --target-tokens "${DREAM_CHUNK_TARGET_TOKENS:-150000}" \
    --min "${DREAM_CHUNK_MIN:-2}" \
    --max "${DREAM_CHUNK_MAX:-8}" \
    --hard-max "${DREAM_CHUNK_HARD_MAX:-180000}"

  CHUNK_COUNT=$(ls "$TMP/chunks/chunk-"*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$CHUNK_COUNT" -lt 2 ]]; then
    echo "dream.sh: ERROR  chunker produced $CHUNK_COUNT chunks; expected >= 2" >&2
    exit 1
  fi

  # ============================================================
  # Stage 3b: parallel map calls (Haiku)
  # ============================================================
  echo "[3b/4] launching $CHUNK_COUNT parallel map calls (model: ${MAP_MODEL:-claude-haiku-4-5-20251001})…"

  MAP_MODEL_USE="${MAP_MODEL:-claude-haiku-4-5-20251001}"
  MAP_SYSTEM_FILE="$PROMPTS_DIR/map-system.md"
  MAP_USER_TEMPLATE_FILE="$PROMPTS_DIR/map.md"
  declare -a MAP_PIDS=()

  # Read chunks-meta.json for date ranges to substitute into the map prompt
  for chunk_file in "$TMP/chunks/chunk-"*.md; do
    chunk_id=$(basename "$chunk_file" .md | sed 's/chunk-//')

    # Substitute {TODAY}, {CHUNK_RANGE}, {CHUNK_CONTENT} into map.md template.
    # CHUNK_RANGE comes from chunks-meta.json.
    CHUNK_RANGE=$(python3 -c '
import json, sys
meta = json.load(open(sys.argv[1]))
entries = {str(e["chunk_id"]): e["start"] + " -> " + e["end"] for e in meta["chunks"]}
print(entries.get(sys.argv[2], "unknown"))
' "$TMP/chunks/chunks-meta.json" "$chunk_id")

    MAP_PROMPT=$(TEMPLATE="$(cat "$MAP_USER_TEMPLATE_FILE")" \
                 TODAY="$DATE" \
                 CHUNK_RANGE="$CHUNK_RANGE" \
                 CHUNK_CONTENT="$(cat "$chunk_file")" \
                 python3 -c '
import os
t = os.environ["TEMPLATE"]
t = t.replace("{TODAY}", os.environ["TODAY"])
t = t.replace("{CHUNK_RANGE}", os.environ["CHUNK_RANGE"])
t = t.replace("{CHUNK_CONTENT}", os.environ["CHUNK_CONTENT"])
print(t, end="")
')

    # Background launch; prompt via stdin (avoids ARG_MAX).
    (
      printf '%s' "$MAP_PROMPT" | timeout 600 claude --print \
        --model "$MAP_MODEL_USE" \
        --bare \
        --no-session-persistence \
        --system-prompt-file "$MAP_SYSTEM_FILE" \
        --output-format json \
        --tools "" \
        --permission-mode bypassPermissions \
        > "$TMP/responses/response-${chunk_id}.json" \
        2> "$TMP/responses/error-${chunk_id}.log"
    ) &
    MAP_PIDS+=("$!:${chunk_id}")
  done

  # Wait for all PIDs, collect failures.
  FAILED_CHUNKS=()
  for pid_id in "${MAP_PIDS[@]}"; do
    pid="${pid_id%:*}"
    cid="${pid_id##*:}"
    if ! wait "$pid"; then
      FAILED_CHUNKS+=("$cid")
    fi
  done

  if [[ ${#FAILED_CHUNKS[@]} -gt 0 ]]; then
    echo "dream.sh: ERROR  map calls failed (non-zero exit) for chunks: ${FAILED_CHUNKS[*]}" >&2
    exit 1
  fi

  # Post-wait, check each response JSON for is_error / max_tokens.
  for chunk_file in "$TMP/chunks/chunk-"*.md; do
    chunk_id=$(basename "$chunk_file" .md | sed 's/chunk-//')
    response_json="$TMP/responses/response-${chunk_id}.json"
    python3 - "$response_json" "$chunk_id" <<'PYEOF' || exit 1
import json, sys
path, cid = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"dream.sh: ERROR  chunk {cid} response unparseable: {e}", file=sys.stderr)
    sys.exit(1)
if data.get("is_error"):
    print(f"dream.sh: ERROR  chunk {cid} returned is_error=true: {data.get('result','')[:200]}", file=sys.stderr)
    sys.exit(1)
stop_reason = data.get("stop_reason") or ""
if stop_reason in ("max_tokens", "refusal"):
    print(f"dream.sh: ERROR  chunk {cid} stop_reason={stop_reason}", file=sys.stderr)
    sys.exit(1)
result = data.get("result", "")
if not result.strip():
    print(f"dream.sh: ERROR  chunk {cid} result empty", file=sys.stderr)
    sys.exit(1)
PYEOF
  done

  # Extract each result into extracts/extract-N.md.
  for chunk_file in "$TMP/chunks/chunk-"*.md; do
    chunk_id=$(basename "$chunk_file" .md | sed 's/chunk-//')
    response_json="$TMP/responses/response-${chunk_id}.json"
    extract_md="$TMP/extracts/extract-${chunk_id}.md"
    python3 - "$response_json" "$extract_md" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
open(sys.argv[2], "w", encoding="utf-8").write(data.get("result", ""))
PYEOF
  done

  # ============================================================
  # Stage 3c: concatenate extracts with separators (chronological)
  # ============================================================
  echo "[3c/4] concatenating extracts…"
  python3 - "$TMP" <<'PYEOF' > "$TMP/extracts-concat.md"
import json, sys
from pathlib import Path
tmp = Path(sys.argv[1])
meta = json.loads((tmp / "chunks" / "chunks-meta.json").read_text())
parts = []
for entry in sorted(meta["chunks"], key=lambda e: e["chunk_id"]):
    cid = entry["chunk_id"]
    rng = f"{entry['start']} -> {entry['end']}"
    body = (tmp / "extracts" / f"extract-{cid}.md").read_text(encoding="utf-8").strip()
    parts.append(f"=== CHUNK {cid} ({rng}) ===\n{body}\n")
print("\n".join(parts))
PYEOF

  CONCAT_BYTES=$(wc -c < "$TMP/extracts-concat.md" | tr -d ' ')
  echo "      extracts-concat.md: ${CONCAT_BYTES} bytes"

  # ============================================================
  # Stage 3d: reduce call (Sonnet, MCPs active)
  # ============================================================
  echo "[3d/4] reduce via Claude ($MODEL)…"

  RECONCILE_TEMPLATE="$(cat "$PROMPTS_DIR/reconcile.md")"
  SESSIONS_CONTENT="$(cat "$TMP/extracts-concat.md")"
  VAULT_CONTENT="$(cat "$TMP/vault.md")"

  PROMPT="$(WINDOW="$WINDOW_LABEL" \
             TODAY="$DATE" \
             SESSIONS="$SESSIONS_CONTENT" \
             VAULT="$VAULT_CONTENT" \
             TEMPLATE="$RECONCILE_TEMPLATE" \
           python3 -c '
import os
t = os.environ["TEMPLATE"]
t = t.replace("{TODAY}",   os.environ["TODAY"])
t = t.replace("{WINDOW}",  os.environ["WINDOW"])
t = t.replace("{SESSIONS}", os.environ["SESSIONS"])
t = t.replace("{VAULT}",    os.environ["VAULT"])
print(t, end="")
')"

  SYSTEM_PROMPT=""
  if [[ -f "$PROMPTS_DIR/system.md" ]]; then
    SYSTEM_PROMPT="$(cat "$PROMPTS_DIR/system.md")"
  fi

  RESPONSE_JSON="$TMP/response.json"
  USAGE_LOG="$SKILL_DIR/.usage-log.jsonl"

  CLAUDE_ARGS=(
    --model "$MODEL"
    --print
    --output-format json
    --tools ""
    --permission-mode bypassPermissions
  )
  if [[ "$NO_MCP" != "1" ]] && [[ -n "$MCP_CONFIG" ]] && [[ -f "$MCP_CONFIG" ]]; then
    CLAUDE_ARGS+=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
  fi
  if [[ -n "$SYSTEM_PROMPT" ]]; then
    CLAUDE_ARGS+=(--append-system-prompt "$SYSTEM_PROMPT")
  fi

  printf '%s' "$PROMPT" | claude "${CLAUDE_ARGS[@]}" > "$RESPONSE_JSON"

  if [[ ! -s "$RESPONSE_JSON" ]]; then
    echo "dream.sh: ERROR  reduce returned empty response" >&2
    exit 1
  fi

  # Continue to existing Stage 4 (save report + log usage)
fi

# ============================================================
# Stage 4: extract report + log usage, emit summary
# ============================================================

echo "[4/4] save report + log usage…"

# shellcheck disable=SC2016
OUTPUT="$OUTPUT_REPORT" \
RESPONSE_JSON="$RESPONSE_JSON" \
USAGE_LOG="$USAGE_LOG" \
DATE="$DATE" \
MODEL="$MODEL" \
SINCE="$WINDOW_LABEL" \
VERBOSE="$VERBOSE" \
python3 <<'PYEOF'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

response_path = Path(os.environ["RESPONSE_JSON"])
output_path   = Path(os.environ["OUTPUT"])
log_path      = Path(os.environ["USAGE_LOG"])
verbose       = os.environ.get("VERBOSE", "0") == "1"

with response_path.open() as f:
    data = json.load(f)

if data.get("is_error"):
    print(f"  ERROR: claude reported error: {data.get('result', 'unknown')}", file=sys.stderr)
    sys.exit(1)

result = data.get("result", "")
if not result.strip():
    print("  ERROR: claude returned empty result", file=sys.stderr)
    sys.exit(1)

# Strip any LLM preamble before YAML frontmatter `---` opener
lines = result.splitlines(keepends=True)
stripped = 0
found_fence = False
for i, line in enumerate(lines):
    if line.strip() == "---":
        if i > 0:
            stripped = i
            result = "".join(lines[i:])
        found_fence = True
        break

if not found_fence:
    print("  WARN: report missing YAML frontmatter — keeping raw output", file=sys.stderr)
elif stripped > 0:
    print(f"  preamble-strip removed {stripped} line(s) before frontmatter")

# Atomic write: tmp file → fsync → rename
output_path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(
    mode="w",
    dir=str(output_path.parent),
    prefix=output_path.stem + ".",
    suffix=".tmp",
    delete=False,
    encoding="utf-8",
) as tmp:
    tmp.write(result)
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp_path = Path(tmp.name)
tmp_path.replace(output_path)

usage = data.get("usage", {}) or {}
in_tok       = usage.get("input_tokens", 0)
out_tok      = usage.get("output_tokens", 0)
cache_read   = usage.get("cache_read_input_tokens", 0)
cache_create = usage.get("cache_creation_input_tokens", 0)
cost         = data.get("total_cost_usd", 0.0)
duration_ms  = data.get("duration_ms", 0)

report_bytes = output_path.stat().st_size
print(f"  wrote {output_path} ({report_bytes} bytes)")
if verbose:
    print(f"  tokens: {in_tok:,} fresh / {cache_read:,} cached / "
          f"{cache_create:,} cache-write / {out_tok:,} out")
    print(f"  cost:   ${cost:.4f}    duration: {duration_ms/1000:.1f}s")

row = {
    "ts": datetime.now(timezone.utc).isoformat(),
    "date": os.environ["DATE"],
    "model": os.environ["MODEL"],
    "window": os.environ["SINCE"],
    "input_tokens": in_tok,
    "output_tokens": out_tok,
    "cache_read_input_tokens": cache_read,
    "cache_creation_input_tokens": cache_create,
    "cost_usd": cost,
    "duration_ms": duration_ms,
    "report_bytes": report_bytes,
}
log_path.parent.mkdir(parents=True, exist_ok=True)
with log_path.open("a") as f:
    f.write(json.dumps(row) + "\n")

if verbose:
    total_cost = 0.0
    total_runs = 0
    with log_path.open() as f:
        for line in f:
            try:
                r = json.loads(line)
                total_cost += float(r.get("cost_usd", 0.0))
                total_runs += 1
            except (json.JSONDecodeError, ValueError):
                continue
    print(f"  logged → {log_path}")
    print(f"  lifetime: {total_runs} runs, ${total_cost:.2f} total")
PYEOF

# ============================================================
# Stamp .last-run so the next dream cycle resumes from this point.
# Atomic write: tmp file → rename. Only reached when stages 1-4 succeed
# (set -euo pipefail ensures any earlier failure aborts the script).
# ============================================================
LAST_RUN_TMP="$(mktemp "${LAST_RUN_FILE}.XXXXXX")"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$LAST_RUN_TMP"
mv "$LAST_RUN_TMP" "$LAST_RUN_FILE"

echo ""
echo "==============================================="
echo "  dream cycle complete."
echo "==============================================="
echo "  review:  $OUTPUT_REPORT"
echo "  apply:   ./dream.sh --apply   (after you've read the report)"
echo "  undo:    ./scripts/apply_undo.sh $DATE"
