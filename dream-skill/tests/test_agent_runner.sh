#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/run-agent-batches.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work"

cat > "$TMP/instructions.md" <<'MD'
# Test contract
Write the required JSON.
MD
cat > "$TMP/work/route-batches.json" <<'JSON'
[{"batch_id":"route-0001","candidates":[{"candidate_id":"c-test","candidate":{"content":"x"}}]}]
JSON
cat > "$TMP/fake-codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
prompt=$(cat)
input=$(printf '%s\n' "$prompt" | awk -F': ' '/^input_path:/ {print $2}')
marker="${out}.failed-once"
if [ ! -e "$marker" ]; then touch "$marker"; exit 7; fi
jq '[.candidates[] | {candidate_id:.candidate_id}]' "$input" > "$out"
SH
chmod +x "$TMP/fake-codex"

"$RUNNER" --stage route --workdir "$TMP/work" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-codex" --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.failed == 0 and .completed == 1 and .results[0].attempts == 2' "$TMP/work/route-run-summary.json" >/dev/null
[ "$(stat -f '%Lp' "$TMP/work/route-out-route-0001.json")" = "600" ]

"$RUNNER" --stage route --workdir "$TMP/work" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-codex" --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.results[0].status == "skipped-existing" and .results[0].attempts == 0' "$TMP/work/route-run-summary.json" >/dev/null

mkdir -p "$TMP/hard"
cp "$TMP/work/route-batches.json" "$TMP/hard/route-batches.json"
cat > "$TMP/fake-hard-error" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "ERROR: You've hit your usage limit." >&2
exit 1
SH
chmod +x "$TMP/fake-hard-error"
if "$RUNNER" --stage route --workdir "$TMP/hard" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-hard-error" --concurrency 1 --retries 3 --timeout 30 >/dev/null; then
  echo "hard account error unexpectedly succeeded" >&2
  exit 1
fi
jq -e '.results[0].status == "non-retryable-agent-error" and .results[0].attempts == 1' \
  "$TMP/hard/route-run-summary.json" >/dev/null

echo "test_agent_runner: ok"
