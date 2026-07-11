#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/dream-run.py"
TMP="$(mktemp -d)"
if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
  echo "test temp: $TMP" >&2
else
  trap 'rm -rf "$TMP"' EXIT
fi
SINCE=$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F)

mkdir -p "$TMP/chats/project" "$TMP/empty-codex" "$TMP/vault/wiki" "$TMP/reports"
cat > "$TMP/chats/project/chat.jsonl" <<'JSONL'
{"message":{"role":"user","content":[{"type":"text","text":"I prefer concise reports. Taylor Park mentioned a new project idea."}]}}
{"message":{"role":"assistant","content":[{"type":"text","text":"The user may prefer weekly summaries."}]}}
JSONL
touch -t "${SINCE//-/}1200" "$TMP/chats/project/chat.jsonl"
cat > "$TMP/vault/wiki/Preferences.md" <<'MD'
# Reports

## Preferences

- The user prefers practical answers.
MD
cat > "$TMP/config.toml" <<EOF
reports_dir = "$TMP/reports"

[vaults.me]
root = "$TMP/vault"
description = "Identity and personal preferences"
EOF

cat > "$TMP/fake-codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
prompt=$(cat)
stage=$(printf '%s\n' "$prompt" | awk -F': ' '/^stage:/ {print $2}')
input=$(printf '%s\n' "$prompt" | awk -F': ' '/^input_path:/ {print $2}')
case "$stage" in
  map)
    header=$(head -n 1 "$input")
    source_chat=$(printf '%s\n' "$header" | sed -E 's/^.*source_chat=(.*) source_date=[0-9-]+ =====$/\1/')
    source_date=$(printf '%s\n' "$header" | sed -E 's/^.*source_date=([0-9-]+) =====$/\1/')
    jq -n --arg chat "$source_chat" --arg date "$source_date" '[
      {"content":"The user prefers concise reports.","confidence":"high","source_chat":$chat,"source_date":$date,"source_role":"user","source_event":1,"evidence":"I prefer concise reports.","type":"preference","suggested_section":"Preferences","memory_tier":"stable"},
      {"content":"The user may prefer weekly summaries.","confidence":"medium","source_chat":$chat,"source_date":$date,"source_role":"assistant_context","source_event":2,"evidence":"The user may prefer weekly summaries.","type":"preference","suggested_section":"Preferences","memory_tier":"stable"},
      {"content":"Taylor Park mentioned a new project idea.","confidence":"high","source_chat":$chat,"source_date":$date,"source_role":"user","source_event":1,"evidence":"Taylor Park mentioned a new project idea.","type":"relationship","suggested_section":"People","memory_tier":"stable"}
    ]' > "$out"
    ;;
  route)
    jq '[. as $batch | .candidates[] | . as $candidate | ($candidate.allowed_page_ids[0]) as $pid | ($batch.page_catalog[] | select(.page_id==$pid)) as $page | {candidate_id:$candidate.candidate_id,status:"routed",vault:$page.vault,page:$page.page,section:"Preferences",routing_confidence:"high"}]' "$input" > "$out"
    ;;
  reconcile)
    jq '[. as $batch | .candidates[] | {candidate_id:.candidate_id,decision:{action:"new",mode:"append",target:{vault:$batch.target.vault,page:$batch.target.page,section:.route.section},content:.candidate.content,candidate_confidence:.candidate.confidence,needs_review:(.candidate.confidence != "high"),rationale:"Preference is absent."}}]' "$input" > "$out"
    ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP/fake-codex"

export DREAM_CLAUDE_PROJECTS_ROOT="$TMP/chats"
export DREAM_CODEX_SESSIONS_ROOT="$TMP/empty-codex"
"$RUNNER" --source claude --since "$SINCE" --shadow --keep-artifacts \
  --home "$TMP/state" --config "$TMP/config.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" --map-concurrency 1 --route-concurrency 1 \
  --reconcile-concurrency 1 > "$TMP/result.json"

RUN_ID=$(jq -er '.runs[0].run_id' "$TMP/result.json")
STATE="$TMP/state/runs/$RUN_ID/state.json"
jq -e '.runs[0].transcripts == 1' "$TMP/result.json" >/dev/null
jq -e '.status == "shadow-complete" and .marker_allowed == false' "$STATE" >/dev/null
jq -e '[.stages.find,.stages.map,.stages.reduce,.stages.route,.stages.reconcile,.stages.apply,.stages.receipt] | all(.status == "success")' "$STATE" >/dev/null || { jq . "$STATE" >&2; exit 1; }
[ ! -e "$TMP/state/last-run" ]
[ -s "$TMP/state/shadow-markers/last-run" ]
rg -Fxq -- '- The user prefers practical answers.' "$TMP/vault/wiki/Preferences.md"
! rg -Fq -- 'The user prefers concise reports.' "$TMP/vault/wiki/Preferences.md"
! rg -Fq -- 'The user may prefer weekly summaries.' "$TMP/vault/wiki/Preferences.md"
jq -e '.[0].page_catalog | length > 0' "$TMP/state/runs/$RUN_ID/route-batches.json" >/dev/null
jq -e '.[0].target_page_scope == "routed-section-plus-lexical-matches"' "$TMP/state/runs/$RUN_ID/reconcile-batches.json" >/dev/null
jq -e '.gaps == []' "$TMP/state/gaps/$RUN_ID.json" >/dev/null
[ "$(wc -l < "$TMP/state/metrics/runs.jsonl" | tr -d ' ')" -ge 1 ]
jq -e 'select(.status == "review-only")' "$TMP/state/metrics/runs.jsonl" >/dev/null
jq -e 'length == 1 and .[0].detected_names == ["Taylor Park"]' \
  "$TMP/state/runs/$RUN_ID/people-review-queue.json" >/dev/null
[ ! -e "$TMP/state/people-review-queue.md" ]

WORKDIR="$TMP/state/runs/$RUN_ID"
jq '.error = "stale failure from an earlier attempt"' "$STATE" > "$WORKDIR/state.tmp"
mv "$WORKDIR/state.tmp" "$STATE"
chmod 600 "$STATE"
printf 'tokens used\n999,999\n' > "$WORKDIR/route-log-route-9999-attempt-01.txt"
chmod 600 "$WORKDIR/route-log-route-9999-attempt-01.txt"

"$RUNNER" --resume "$RUN_ID" --promote-shadow \
  --home "$TMP/state" --config "$TMP/config.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" --map-concurrency 1 --route-concurrency 1 \
  --reconcile-concurrency 1 > "$TMP/real-result.json"
REAL_RUN_ID=$(jq -er '.runs[0].run_id' "$TMP/real-result.json")
REAL_STATE="$TMP/state/runs/$REAL_RUN_ID.json"
jq -e '.status == "completed" and .marker_allowed == true' "$REAL_STATE" >/dev/null
jq -e 'has("error") | not' "$REAL_STATE" >/dev/null
jq -e '.timing.started_at != null and .timing.ended_at != null and .timing.duration_seconds >= 0' \
  "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
jq -e '.usage.total_tokens_observed < 999999' "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
MARKER_VALUE=$(jq -r '.marker_value' "$REAL_STATE")
[[ "$MARKER_VALUE" =~ ^[0-9]+$ ]]
[ "$(cat "$TMP/state/last-run")" = "$MARKER_VALUE" ]
rg -Fq -- '- The user prefers concise reports.' "$TMP/vault/wiki/Preferences.md"
! rg -Fq -- 'The user may prefer weekly summaries.' "$TMP/vault/wiki/Preferences.md"
[ "$(find "$TMP/state/queue/sidecars" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
rg -Fq -- 'The user may prefer weekly summaries.' "$TMP/state/queue/pending.md"
python3 - "$TMP/state" <<'PY'
import stat
import sys
from pathlib import Path
bad = []
for path in [Path(sys.argv[1]), *Path(sys.argv[1]).rglob("*")]:
    if path.is_symlink():
        continue
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        bad.append(str(path))
assert not bad, bad
PY

echo "test_dream_run_e2e: ok"
