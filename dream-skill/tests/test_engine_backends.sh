#!/usr/bin/env bash
# Unit tests for the pluggable agent engine (codex|claude). Stub bins only —
# no real LLM calls. Covers:
#   1. --engine codex explicit dispatch still works (run-agent-batches.py).
#   2. --engine claude dispatch: stdout -> output_path capture path.
#   3. Claude rate-limit/quota text fails fast as non-retryable (no retry burn).
#   4. dream-run.py's validate_environment() checks the *selected* engine's
#      bin only (codex absent doesn't block a claude run; missing claude-bin
#      fails preflight cleanly).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/run-agent-batches.py"
DREAM_RUN="$SKILL_DIR/scripts/dream-run.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/instructions.md" <<'MD'
# Test contract
Write the required JSON.
MD

# ── Case 1: codex dispatch, --engine codex explicit ─────────────────────────
mkdir -p "$TMP/work-codex"
echo "unit text" > "$TMP/unit-0001.txt"
cat > "$TMP/work-codex/map-units.json" <<JSON
[{"batch_id":"map-0001","kind":"bundle","unit_path":"$TMP/unit-0001.txt"}]
JSON
cat > "$TMP/fake-codex.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
cat >/dev/null
printf '%s' '[{"fact":"canned-codex-value"}]' > "$out"
SH
chmod +x "$TMP/fake-codex.sh"

"$RUNNER" --stage map --engine codex --workdir "$TMP/work-codex" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-codex.sh" --concurrency 1 --retries 0 --timeout 30 >/dev/null
jq -e '.completed == 1 and .failed == 0' "$TMP/work-codex/map-run-summary.json" >/dev/null
diff <(jq -cS . "$TMP/work-codex/map-out-map-0001.json") <(printf '%s' '[{"fact":"canned-codex-value"}]' | jq -cS .) >/dev/null

# ── Case 2: claude dispatch, stdout -> output_path capture ──────────────────
mkdir -p "$TMP/work-claude"
cat > "$TMP/work-claude/route-batches.json" <<'JSON'
[{"batch_id":"route-0001","candidates":[{"candidate_id":"c-1","candidate":{"content":"x"}}]}]
JSON
cat > "$TMP/fake-claude.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf '%s' '```json
[{"candidate_id":"c-1","decision":"route"}]
```'
SH
chmod +x "$TMP/fake-claude.sh"

"$RUNNER" --stage route --engine claude --workdir "$TMP/work-claude" --instructions "$TMP/instructions.md" \
  --claude-bin "$TMP/fake-claude.sh" --concurrency 1 --retries 0 --timeout 30 >/dev/null
jq -e '.completed == 1 and .failed == 0' "$TMP/work-claude/route-run-summary.json" >/dev/null
jq -e '([.[].candidate_id] | sort) == ["c-1"]' "$TMP/work-claude/route-out-route-0001.json" >/dev/null

# ── Case 3: non-retryable claude rate-limit (new fragment, not the pre- ─────
# existing generic "usage limit" one) fails fast, no retry burn.
mkdir -p "$TMP/work-quota"
cp "$TMP/work-claude/route-batches.json" "$TMP/work-quota/route-batches.json"
cat > "$TMP/fake-claude-quota.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "API Error: rate_limit_error - too many requests" >&2
exit 1
SH
chmod +x "$TMP/fake-claude-quota.sh"

if "$RUNNER" --stage route --engine claude --workdir "$TMP/work-quota" --instructions "$TMP/instructions.md" \
  --claude-bin "$TMP/fake-claude-quota.sh" --concurrency 1 --retries 3 --timeout 30 >/dev/null; then
  echo "claude rate-limit error unexpectedly succeeded" >&2
  exit 1
fi
jq -e '.results[0].status == "non-retryable-agent-error" and .results[0].attempts == 1' \
  "$TMP/work-quota/route-run-summary.json" >/dev/null

# ── Case 4: dream-run.py validate_environment checks the selected engine ───
# only. codex absent must not block a claude run; missing claude-bin must
# fail preflight cleanly.
mkdir -p "$TMP/vault"
cat > "$TMP/config.toml" <<EOF
[vaults.test]
root = "$TMP/vault"
description = "test vault"
EOF
cat > "$TMP/fake-claude-ok" <<'SH'
#!/usr/bin/env bash
echo ok
exit 0
SH
chmod +x "$TMP/fake-claude-ok"
SINCE=$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F)

# 4a: missing --claude-bin fails preflight cleanly, no state written.
if "$DREAM_RUN" --engine claude --shadow --claude-bin nonexistent-claude-binary-xyz \
  --config "$TMP/config.toml" --home "$TMP/home-neg" --since "$SINCE" \
  >"$TMP/out-neg" 2>"$TMP/err-neg"; then
  echo "missing claude-bin unexpectedly passed preflight" >&2
  exit 1
fi
rg -q 'preflight failed:.*Claude executable not found on PATH' "$TMP/err-neg"
[ ! -e "$TMP/home-neg" ]

# 4b: codex absent (bogus --codex-bin) must not block engine=claude preflight.
mkdir -p "$TMP/empty-claude-projects" "$TMP/empty-codex-sessions"
DREAM_CLAUDE_PROJECTS_ROOT="$TMP/empty-claude-projects" \
DREAM_CODEX_SESSIONS_ROOT="$TMP/empty-codex-sessions" \
"$DREAM_RUN" --engine claude --shadow --codex-bin "/no/such/codex-binary" \
  --claude-bin "$TMP/fake-claude-ok" --config "$TMP/config.toml" --home "$TMP/home-pos" \
  --since "$SINCE" >"$TMP/out-pos" 2>"$TMP/err-pos" || true
if rg -qi 'preflight failed|codex executable' "$TMP/err-pos"; then
  echo "engine=claude preflight unexpectedly checked/failed on absent codex bin:" >&2
  cat "$TMP/err-pos" >&2
  exit 1
fi

echo "test_engine_backends: ok"
