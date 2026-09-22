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
if [ -n "${FAKE_CODEX_ARGS:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_CODEX_ARGS"
fi
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

FAKE_CODEX_ARGS="$TMP/codex-args" \
  "$RUNNER" --stage route --workdir "$TMP/work" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-codex" --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.failed == 0 and .completed == 1 and .results[0].attempts == 2' "$TMP/work/route-run-summary.json" >/dev/null
rg -q -- '--ignore-user-config' "$TMP/codex-args"
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
jq -e '.results[0].status == "non-retryable-agent-error" and .results[0].attempts == 1 and .results[0].error_class == "quota" and .error_classes.quota == 1' \
  "$TMP/hard/route-run-summary.json" >/dev/null

# Candidate-like prose in a log is not an operational account error.  It must
# not open the stage circuit merely because it contains a quota phrase.
mkdir -p "$TMP/noise"
cp "$TMP/work/route-batches.json" "$TMP/noise/route-batches.json"
cat > "$TMP/fake-log-noise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
cat >/dev/null
if [ ! -e "${out}.noise-failed-once" ]; then
  touch "${out}.noise-failed-once"
  echo "candidate text: usage limit preferences are not durable" >&2
  exit 1
fi
printf '%s\n' '[{"candidate_id":"c-test"}]' > "$out"
SH
chmod +x "$TMP/fake-log-noise"
"$RUNNER" --stage route --workdir "$TMP/noise" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-log-noise" --concurrency 1 --retries 1 --timeout 30 >/dev/null
jq -e '.failed == 0 and .results[0].attempts == 2 and .results[0].retry_error_classes == ["agent"]' \
  "$TMP/noise/route-run-summary.json" >/dev/null

# A quota/auth/configuration failure applies to the stage, not just one batch.
# Stop queued work so an outage does not multiply cost or hide reusable output.
mkdir -p "$TMP/circuit"
cat > "$TMP/circuit/route-batches.json" <<'JSON'
[
  {"batch_id":"route-0001","candidates":[{"candidate_id":"c-one","candidate":{"content":"x"}}]},
  {"batch_id":"route-0002","candidates":[{"candidate_id":"c-two","candidate":{"content":"x"}}]},
  {"batch_id":"route-0003","candidates":[{"candidate_id":"c-three","candidate":{"content":"x"}}]}
]
JSON
cat > "$TMP/fake-circuit-error" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
count=0
if [ -f "$FAKE_CALL_COUNT" ]; then read -r count < "$FAKE_CALL_COUNT"; fi
printf '%s\n' "$((count + 1))" > "$FAKE_CALL_COUNT"
echo "ERROR: You've hit your usage limit." >&2
exit 1
SH
chmod +x "$TMP/fake-circuit-error"
if FAKE_CALL_COUNT="$TMP/circuit-calls" \
  "$RUNNER" --stage route --workdir "$TMP/circuit" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-circuit-error" --concurrency 1 --retries 3 --timeout 30 >/dev/null; then
  echo "stage circuit unexpectedly succeeded" >&2
  exit 1
fi
[ "$(cat "$TMP/circuit-calls")" = "1" ]
jq -e '.failed == 3 and .error_classes.quota == 3 and ([.results[] | select(.status == "non-retryable-agent-error")] | length) == 1 and ([.results[] | select(.status == "stage-circuit-open")] | length) == 2' \
  "$TMP/circuit/route-run-summary.json" >/dev/null

# Transient transport errors retry after an explicit shared backoff and retain
# their classification even when the batch later succeeds.
mkdir -p "$TMP/transport"
cp "$TMP/work/route-batches.json" "$TMP/transport/route-batches.json"
cat > "$TMP/fake-transport-error" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
cat >/dev/null
attempts_file="${out}.transport-attempts"
attempts=0
if [ -f "$attempts_file" ]; then read -r attempts < "$attempts_file"; fi
attempts=$((attempts + 1))
printf '%s\n' "$attempts" > "$attempts_file"
if [ "$attempts" -lt 3 ]; then
  echo "ERROR: stream disconnected before completion: network connection lost" >&2
  exit 1
fi
printf '%s\n' '[{"candidate_id":"c-test"}]' > "$out"
SH
chmod +x "$TMP/fake-transport-error"
"$RUNNER" --stage route --workdir "$TMP/transport" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-transport-error" --concurrency 1 --retries 2 \
  --retry-backoff 1 --timeout 30 >/dev/null
jq -e '.failed == 0 and .results[0].attempts == 3 and .results[0].seconds >= 2.8 and .results[0].retry_error_classes == ["transport","transport"] and .results[0].retry_backoff_seconds == [1,2]' \
  "$TMP/transport/route-run-summary.json" >/dev/null

# A transport outage receives the full configured attempt budget.  Only after
# the third process fails should Dream open the circuit and preserve queued work.
mkdir -p "$TMP/transport-outage"
cp "$TMP/circuit/route-batches.json" "$TMP/transport-outage/route-batches.json"
cat > "$TMP/fake-transport-outage" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
count=0
if [ -f "$FAKE_CALL_COUNT" ]; then read -r count < "$FAKE_CALL_COUNT"; fi
printf '%s\n' "$((count + 1))" > "$FAKE_CALL_COUNT"
echo "ERROR: stream disconnected before completion: DNS error" >&2
exit 1
SH
chmod +x "$TMP/fake-transport-outage"
if FAKE_CALL_COUNT="$TMP/transport-outage-calls" \
  "$RUNNER" --stage route --workdir "$TMP/transport-outage" --instructions "$TMP/instructions.md" \
  --codex-bin "$TMP/fake-transport-outage" --concurrency 1 --retries 2 \
  --retry-backoff 0 --timeout 30 >/dev/null; then
  echo "transport outage circuit unexpectedly succeeded" >&2
  exit 1
fi
[ "$(cat "$TMP/transport-outage-calls")" = "3" ]
jq -e '.failed == 3 and .error_classes.transport == 3 and ([.results[] | select(.status == "transient-retries-exhausted" and .attempts == 3)] | length) == 1 and ([.results[] | select(.status == "stage-circuit-open")] | length) == 2' \
  "$TMP/transport-outage/route-run-summary.json" >/dev/null

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
