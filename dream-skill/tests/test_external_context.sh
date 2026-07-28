#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/dream-run.py"
FINDER="$SKILL_DIR/scripts/find-chats.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dream-external-context.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/claude" "$TMP/codex" "$TMP/external" "$TMP/attacker" \
  "$TMP/vault/wiki" "$TMP/reports"
printf '%s\n' '{"message":{"role":"user","content":"external fact"}}' > "$TMP/external/meeting.jsonl"
printf '%s\n' '{"message":{"role":"user","content":"ambient injection"}}' > "$TMP/attacker/injected.jsonl"
PAST_STAMP=$(date -v-1M +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 minute ago' +%Y%m%d%H%M.%S)
touch -t "$PAST_STAMP" "$TMP/external/meeting.jsonl" "$TMP/attacker/injected.jsonl"

# The generic root participates in Claude/all discovery, never Codex discovery,
# and bypasses Claude transcript private-state sidecars.
mkdir -p "$TMP/private/scripts"
cat > "$TMP/private/scripts/private-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$PRIVATE_STATE_CALLS"
echo ignore
SH
chmod +x "$TMP/private/scripts/private-state.sh"
export PRIVATE_STATE_CALLS="$TMP/private-state-calls"
: > "$PRIVATE_STATE_CALLS"

COMMON_ENV=(
  DREAM_CLAUDE_PROJECTS_ROOT="$TMP/claude"
  DREAM_CODEX_SESSIONS_ROOT="$TMP/codex"
  DREAM_EXTERNAL_JSONL_ROOT="$TMP/external"
  DREAM_MARKER_DIR="$TMP/markers"
  DREAM_SKILL_HOME="$TMP/private"
)
OUT_CLAUDE=$(env "${COMMON_ENV[@]}" "$FINDER" --source claude --all)
OUT_ALL=$(env "${COMMON_ENV[@]}" "$FINDER" --source all --all)
OUT_CODEX=$(env "${COMMON_ENV[@]}" "$FINDER" --source codex --all)
printf '%s\n' "$OUT_CLAUDE" | grep -Fq "$TMP/external/meeting.jsonl" \
  || fail "external JSONL missing from Claude discovery"
printf '%s\n' "$OUT_ALL" | grep -Fq "$TMP/external/meeting.jsonl" \
  || fail "external JSONL missing from all-source discovery"
printf '%s\n' "$OUT_CODEX" | grep -Fq "$TMP/external/meeting.jsonl" \
  && fail "external JSONL leaked into Codex-only discovery"
[ ! -s "$PRIVATE_STATE_CALLS" ] || fail "external JSONL was sent to private-state"

# Candidate provenance beneath the root is deterministically downgraded and
# review-gated; unrelated transcript candidates remain untouched.
python3 - "$SKILL_DIR" "$TMP/external" "$TMP/claude/native.jsonl" <<'PY'
import importlib.util
import sys
from pathlib import Path

skill = Path(sys.argv[1])
sys.path.insert(0, str(skill / "scripts"))
spec = importlib.util.spec_from_file_location("dream_run", skill / "scripts/dream-run.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

root = Path(sys.argv[2]).resolve()
external = {
    "source_chat": str(root / "meeting.jsonl"),
    "confidence": "high",
    "content": "fact",
}
native = {
    "source_chat": sys.argv[3],
    "confidence": "high",
    "content": "native fact",
}
gated = module.force_external_review([external, native], root)
assert gated[0]["confidence"] == "medium"
assert gated[0]["original_confidence"] == "high"
assert gated[0]["policy_review_only"] is True
assert "external_context" in gated[0]["policy_reasons"]
assert gated[1] == native
PY

# The mtime barrier makes a JSONL written in the hook's final integer second
# eligible for find-chats' half-open [start,end) window immediately.
cat > "$TMP/write-now" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$1"
printf '%s\n' '{"message":{"role":"user","content":"fresh"}}' > "$1/fresh.jsonl"
SH
chmod +x "$TMP/write-now"
python3 - "$SKILL_DIR" "$TMP/external-now" "$TMP/write-now" "$TMP/vault" "$TMP/state-boundary" <<'PY'
import importlib.util
import sys
import time
from pathlib import Path

skill, raw_root, executable, raw_vault, raw_home = sys.argv[1:]
sys.path.insert(0, str(Path(skill) / "scripts"))
spec = importlib.util.spec_from_file_location("dream_run", Path(skill) / "scripts/dream-run.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
root = Path(raw_root)
resolved = module.refresh_external_context(
    root,
    (executable, raw_root),
    Path(raw_home).resolve(),
    {"me": (Path(raw_vault).resolve(), "")},
)
mtime_second = int((resolved / "fresh.jsonl").stat().st_mtime)
assert int(time.time()) > mtime_second
PY

cat > "$TMP/fake-codex" <<'SH'
#!/usr/bin/env bash
exit 99
SH
chmod +x "$TMP/fake-codex"

cat > "$TMP/refresh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
counter="$2"
snapshot="$3"
mkdir -p "$root"
count=0
[ ! -f "$counter" ] || count=$(cat "$counter")
printf '%s\n' "$((count + 1))" > "$counter"
env | sort > "$snapshot"
SH
chmod +x "$TMP/refresh"

cat > "$TMP/config.toml" <<EOF
reports_dir = "$TMP/reports"

[external_context]
jsonl_root = "$TMP/hook-output"
refresh_command = ["$TMP/refresh", "$TMP/hook-output", "$TMP/hook-count", "$TMP/hook-env"]

[vaults.me]
root = "$TMP/vault"
description = "test"
EOF

SINCE=$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F)
export DREAM_CLAUDE_PROJECTS_ROOT="$TMP/claude"
export DREAM_CODEX_SESSIONS_ROOT="$TMP/codex"
export DREAM_EXTERNAL_JSONL_ROOT="$TMP/attacker"
export DREAM_TEST_SECRET="must-not-reach-hook"

# A fresh run invokes the hook exactly once. The configured root replaces an
# ambient injection, and the hook receives no DREAM_* variables or secrets.
"$RUNNER" --source claude --since "$SINCE" --shadow --keep-artifacts \
  --home "$TMP/state" --config "$TMP/config.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" > "$TMP/fresh-result.json"
[ "$(cat "$TMP/hook-count")" = "1" ] || fail "fresh run did not invoke hook exactly once"
! grep -q '^DREAM_' "$TMP/hook-env" || fail "hook inherited DREAM_* environment"
! grep -q 'must-not-reach-hook' "$TMP/hook-env" || fail "hook inherited ambient secret"
jq -e '.runs[0].transcripts == 0' "$TMP/fresh-result.json" >/dev/null \
  || fail "ambient external root was not sanitized"
RUN_ID=$(jq -er '.runs[0].run_id' "$TMP/fresh-result.json")
EXPECTED_ROOT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$TMP/hook-output")
jq -e --arg root "$EXPECTED_ROOT" '.external_jsonl_root == $root' \
  "$TMP/state/runs/$RUN_ID/state.json" >/dev/null \
  || fail "canonical external root not persisted in run state"

# Resume reuses retained discovery and provenance; it never refreshes again.
"$RUNNER" --resume "$RUN_ID" --promote-shadow \
  --home "$TMP/state" --config "$TMP/config.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" > "$TMP/resume-result.json"
[ "$(cat "$TMP/hook-count")" = "1" ] || fail "resume invoked external hook"

# An explicit Codex-only run neither invokes nor discovers the generic
# Claude-compatible external context source.
"$RUNNER" --source codex --since "$SINCE" --shadow \
  --home "$TMP/codex-state" --config "$TMP/config.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" > "$TMP/codex-result.json"
[ "$(cat "$TMP/hook-count")" = "1" ] || fail "Codex-only run invoked external hook"
jq -e '.runs[0].transcripts == 0' "$TMP/codex-result.json" >/dev/null \
  || fail "Codex-only runner discovered external JSONL"

# With no configured section, an ambient root is explicitly cleared before the
# finder runs.
cat > "$TMP/no-external.toml" <<EOF
reports_dir = "$TMP/reports"
[vaults.me]
root = "$TMP/vault"
description = "test"
EOF
"$RUNNER" --source claude --since "$SINCE" --shadow \
  --home "$TMP/no-external-state" --config "$TMP/no-external.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" > "$TMP/no-external-result.json"
jq -e '.runs[0].transcripts == 0' "$TMP/no-external-result.json" >/dev/null \
  || fail "ambient external root was active without config"

# Output roots must stay separate from both vault content and Dream state.
cat > "$TMP/overlap.toml" <<EOF
reports_dir = "$TMP/reports"
[external_context]
jsonl_root = "$TMP/vault/private-context"
refresh_command = ["$TMP/refresh", "$TMP/vault/private-context", "$TMP/bad-count", "$TMP/bad-env"]
[vaults.me]
root = "$TMP/vault"
description = "test"
EOF
if "$RUNNER" --source claude --since "$SINCE" --shadow \
  --home "$TMP/overlap-state" --config "$TMP/overlap.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" > "$TMP/overlap-out" 2> "$TMP/overlap-err"; then
  fail "vault-overlapping external root passed preflight"
fi
grep -Fq 'must not overlap configured vaults' "$TMP/overlap-err" \
  || fail "overlap preflight error was not explicit"
[ ! -e "$TMP/bad-count" ] || fail "overlapping hook ran before preflight rejection"

echo "PASS: generic external context hook"
