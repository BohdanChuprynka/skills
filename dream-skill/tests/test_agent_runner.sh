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
[ "$(stat -c '%a' "$TMP/work/route-out-route-0001.json" 2>/dev/null || stat -f '%Lp' "$TMP/work/route-out-route-0001.json")" = "600" ]
[ "$(stat -c '%a' "$TMP/work/route-log-route-0001-attempt-02.txt" 2>/dev/null || stat -f '%Lp' "$TMP/work/route-log-route-0001-attempt-02.txt")" = "600" ]

"$RUNNER" --stage route --workdir "$TMP/work" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-codex" --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.results[0].status == "skipped-existing" and .results[0].attempts == 0' "$TMP/work/route-run-summary.json" >/dev/null
[ "$(wc -l < "$TMP/work/route-attempt-ledger.jsonl" | tr -d ' ')" = "2" ]

# A later recomputation must retain the original attempt logs instead of
# overwriting attempt-01/02 and under-reporting usage.
printf '\nChanged contract.\n' >> "$TMP/instructions.md"
"$RUNNER" --stage route --workdir "$TMP/work" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-codex" --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.results[0].status == "ok" and .results[0].attempt_logs == ["route-log-route-0001-attempt-03.txt"]' \
  "$TMP/work/route-run-summary.json" >/dev/null
[ -f "$TMP/work/route-log-route-0001-attempt-01.txt" ]
[ -f "$TMP/work/route-log-route-0001-attempt-02.txt" ]
[ -f "$TMP/work/route-log-route-0001-attempt-03.txt" ]
[ "$(wc -l < "$TMP/work/route-attempt-ledger.jsonl" | tr -d ' ')" = "3" ]

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

# A syntactically complete ROUTE output can still violate the production
# contract.  Semantic validation must retry that individual batch, then treat
# the repaired output as resumable on the next invocation.
mkdir -p "$TMP/semantic/vault/wiki" "$TMP/semantic/work"
cat > "$TMP/semantic/config.toml" <<EOF
[vaults.test]
root = "$TMP/semantic/vault"
description = "test vault"
EOF
cat > "$TMP/semantic/vault/wiki/page.md" <<'MD'
# Page

## Facts
MD
cat > "$TMP/semantic/work/route-batches.json" <<'JSON'
[{"batch_id":"route-0001","page_catalog":[{"page_id":"p001","vault":"test","page":"wiki/page.md","title":"Page","headings":["Facts"]}],"candidates":[{"candidate_id":"c-semantic","candidate":{"content":"x"},"allowed_page_ids":["p001"]}]}]
JSON
cat > "$TMP/fake-semantic-codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
cat >/dev/null
marker="${out}.semantic-failed-once"
if [ ! -e "$marker" ]; then
  touch "$marker"
  printf '%s\n' '[{"candidate_id":"c-semantic","status":"routed","vault":"test","page":"wiki/page.md","section":null,"routing_confidence":"medium"}]' > "$out"
else
  printf '%s\n' '[{"candidate_id":"c-semantic","status":"routed","vault":"test","page":"wiki/page.md","section":"Facts","routing_confidence":"medium"}]' > "$out"
fi
SH
chmod +x "$TMP/fake-semantic-codex"

"$RUNNER" --stage route --workdir "$TMP/semantic/work" --instructions "$TMP/instructions.md" \
  --config "$TMP/semantic/config.toml" --codex-bin "$TMP/fake-semantic-codex" \
  --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.failed == 0 and .completed == 1 and .results[0].attempts == 2' \
  "$TMP/semantic/work/route-run-summary.json" >/dev/null
jq -e '.[0].section == "Facts"' "$TMP/semantic/work/route-out-route-0001.json" >/dev/null
rg -q 'semantic validation failed:.*requires non-empty section' \
  "$TMP/semantic/work/route-log-route-0001-attempt-01.txt"

"$RUNNER" --stage route --workdir "$TMP/semantic/work" --instructions "$TMP/instructions.md" \
  --config "$TMP/semantic/config.toml" --codex-bin "$TMP/fake-semantic-codex" \
  --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.results[0].status == "skipped-existing" and .results[0].attempts == 0' \
  "$TMP/semantic/work/route-run-summary.json" >/dev/null

echo "test_agent_runner: ok"
