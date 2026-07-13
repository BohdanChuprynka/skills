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
{"message":{"role":"user","content":[{"type":"text","text":"I prefer practical answers and concise reports. Taylor Park mentioned a new project idea."}]}}
{"message":{"role":"assistant","content":[{"type":"text","text":"The user may prefer weekly summaries."}]}}
JSONL
touch -t "${SINCE//-/}1200" "$TMP/chats/project/chat.jsonl"
cat > "$TMP/vault/wiki/Preferences.md" <<'MD'
# Reports

## Preferences

- The user prefers practical answers.
MD
cat > "$TMP/vault/wiki/People.md" <<'MD'
# People

## Community
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
      {"content":"The user prefers practical answers.","confidence":"high","source_chat":$chat,"source_date":$date,"source_role":"user","source_event":1,"evidence":"I prefer practical answers and concise reports.","type":"preference","suggested_section":"Preferences","memory_tier":"stable"},
      {"content":"The user prefers concise reports.","confidence":"high","source_chat":$chat,"source_date":$date,"source_role":"user","source_event":1,"evidence":"I prefer practical answers and concise reports.","type":"preference","suggested_section":"Preferences","memory_tier":"stable"},
      {"content":"The user is currently testing concise reporting workflows.","confidence":"high","source_chat":$chat,"source_date":$date,"source_role":"user","source_event":1,"evidence":"I prefer practical answers and concise reports.","type":"active_work","suggested_section":"Preferences","memory_tier":"current"},
      {"content":"The user may prefer weekly summaries.","confidence":"medium","source_chat":$chat,"source_date":$date,"source_role":"assistant_context","source_event":2,"evidence":"The user may prefer weekly summaries.","type":"preference","suggested_section":"Preferences","memory_tier":"stable"},
      {"content":"Taylor Park mentioned a new project idea.","confidence":"high","source_chat":$chat,"source_date":$date,"source_role":"user","source_event":1,"evidence":"Taylor Park mentioned a new project idea.","type":"relationship","suggested_section":"People","memory_tier":"stable"}
    ]' > "$out"
    ;;
  route)
    jq '[. as $batch | .candidates[] | . as $candidate | ($candidate.allowed_page_ids[0]) as $pid | ($batch.page_catalog[] | select(.page_id==$pid)) as $page | {candidate_id:$candidate.candidate_id,status:"routed",vault:$page.vault,page:$page.page,section:($page.headings[0] // "Overview"),routing_confidence:"high"}]' "$input" > "$out"
    ;;
  reconcile)
    if [ "${DREAM_TEST_INVALID_RECONCILE:-0}" = "1" ]; then
      jq '[. as $batch | .candidates[] | . as $item
        | {candidate_id:$item.candidate_id,decision:{action:"contradict",old_content:"- Missing historical line",rationale:"Conflicts with an old value."}}]' "$input" > "$out"
    else
      jq '[. as $batch | .candidates[] | . as $item
        | ($item.candidate.content == "The user prefers practical answers.") as $duplicate
        | {candidate_id:$item.candidate_id,decision:{action:(if $duplicate then "duplicate" else "new" end),mode:(if $duplicate then "none" else "append" end),target:{vault:$batch.target.vault,page:$batch.target.page,section:$item.route.section},content:(if $duplicate then "" else $item.candidate.content end),candidate_confidence:$item.candidate.confidence,needs_review:(if $duplicate then false else ($item.candidate.confidence != "high") end),rationale:(if $duplicate then "Preference is already present." else "Preference is absent." end)}}]' "$input" > "$out"
    fi
    ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP/fake-codex"

export DREAM_CLAUDE_PROJECTS_ROOT="$TMP/chats"
export DREAM_CODEX_SESSIONS_ROOT="$TMP/empty-codex"
"$RUNNER" --source claude --since "$SINCE" --shadow --keep-artifacts \
  --home "$TMP/state" --config "$TMP/config.toml" --cwd "$TMP" \
  --historical-current-review-days 0 \
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
jq -e '.[0].target_page_scope == "multiple-isolated-page-contexts" and (.[0].page_groups | length) == 2' \
  "$TMP/state/runs/$RUN_ID/reconcile-batches.json" >/dev/null
jq -e '.gaps == []' "$TMP/state/gaps/$RUN_ID.json" >/dev/null
[ "$(wc -l < "$TMP/state/metrics/runs.jsonl" | tr -d ' ')" -ge 1 ]
jq -e 'select(.status == "review-only")' "$TMP/state/metrics/runs.jsonl" >/dev/null
jq -e 'length == 1 and .[0].detected_names == ["Taylor Park"]' \
  "$TMP/state/runs/$RUN_ID/people-review-queue.json" >/dev/null
[ ! -e "$TMP/state/people-review-queue.md" ]

WORKDIR="$TMP/state/runs/$RUN_ID"
jq -e '[.[] | select(.decision.policy_review_only == true)] | length == 1 and .[0].decision.needs_review == true' \
  "$WORKDIR/reconcile-decisions-enforced.json" >/dev/null
jq -e '.counts.reduce.gate_dispositions.policy_review.selected == 1 and .counts.reduce.gate_dispositions.policy_review.dispositions.queued == 1' \
  "$TMP/state/metrics/runs/$RUN_ID.json" >/dev/null
jq -e '[.[] | select(.content == "The user is currently testing concise reporting workflows.")] | length == 1 and .[0].historical_review == true and .[0].confidence == "medium" and .[0].original_confidence == "high"' "$WORKDIR/routable.json" >/dev/null
jq '.error = "stale failure from an earlier attempt"' "$STATE" > "$WORKDIR/state.tmp"
mv "$WORKDIR/state.tmp" "$STATE"
chmod 600 "$STATE"
printf 'tokens used\n999,999\n' > "$WORKDIR/route-log-route-9999-attempt-01.txt"
chmod 600 "$WORKDIR/route-log-route-9999-attempt-01.txt"

"$RUNNER" --resume "$RUN_ID" --promote-shadow \
  --home "$TMP/state" --config "$TMP/config.toml" --cwd "$TMP" \
  --historical-current-review-days 0 \
  --codex-bin "$TMP/fake-codex" --map-concurrency 1 --route-concurrency 1 \
  --reconcile-concurrency 1 > "$TMP/real-result.json"
REAL_RUN_ID=$(jq -er '.runs[0].run_id' "$TMP/real-result.json")
REAL_STATE="$TMP/state/runs/$REAL_RUN_ID.json"
RECEIPT_FILE="$TMP/reports/$REAL_RUN_ID.md"
UNDO_LOG="$TMP/state/undo/$REAL_RUN_ID.jsonl"
jq -e '.status == "completed" and .marker_allowed == true' "$REAL_STATE" >/dev/null
jq -e 'has("error") | not' "$REAL_STATE" >/dev/null
jq -e '.timing.started_at != null and .timing.ended_at != null and .timing.duration_seconds >= 0' \
  "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
jq -e '.usage.total_tokens_observed < 999999' "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
jq -e '.counts.map.prefilter.totals.transcripts == 1 and .counts.map.prefilter.totals.raw_bytes > 0 and .counts.map.prefilter.totals.output_bytes > 0' \
  "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
jq -e '.counts.map.units_detail.max_units_per_source_chat >= 1 and .counts.map.units_detail.by_kind.bundle.units >= 1' \
  "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
jq -e '.counts.reduce.gate_dispositions.policy_review.selected == 1 and .counts.reduce.gate_dispositions.policy_review.dispositions.queued == 1' \
  "$TMP/state/metrics/runs/$REAL_RUN_ID.json" >/dev/null
MARKER_VALUE=$(jq -r '.marker_value' "$REAL_STATE")
[[ "$MARKER_VALUE" =~ ^[0-9]+$ ]]
[ "$(cat "$TMP/state/last-run")" = "$MARKER_VALUE" ]
rg -Fq -- '- The user prefers concise reports.' "$TMP/vault/wiki/Preferences.md"
! rg -Fq -- 'The user may prefer weekly summaries.' "$TMP/vault/wiki/Preferences.md"
rg -Fq -- '- "The user prefers practical answers." — already present in [[me/wiki/Preferences]]' "$RECEIPT_FILE"
! rg -Fq -- '- "" — already present' "$RECEIPT_FILE"
rg -Fxq -- '## Skipped as duplicates' "$RECEIPT_FILE"
rg -Fq -- "--run-id \"$REAL_RUN_ID\"" "$RECEIPT_FILE"
[ -s "$UNDO_LOG" ]
jq -se --arg run_id "$REAL_RUN_ID" \
  'length > 0 and all(.[]; .run_id == $run_id and (.candidate_id | type == "string" and length > 0))' \
  "$UNDO_LOG" >/dev/null
[ ! -e "$TMP/state/undo/$(jq -er '.window.end' "$REAL_STATE").jsonl" ]
[ "$(find "$TMP/state/queue/sidecars" -name '*.json' | wc -l | tr -d ' ')" = "3" ]
rg -Fq -- 'The user may prefer weekly summaries.' "$TMP/state/queue/pending.md"
rg -Fq -- 'The user is currently testing concise reporting workflows.' "$TMP/state/queue/pending.md"
jq -se --arg run_id "$REAL_RUN_ID" 'any(.[]; .historical_review == true and .memory_tier == "current" and .candidate_type == "active_work" and .run_id == $run_id and .run_window.start != null and .model_profile.map != null and .model_profile.engine == "codex" and (.model_profile.efforts | has("map")))' "$TMP/state/queue/sidecars/"*.json >/dev/null
jq -se 'any(.[]; .fact_class == "active_state" and .policy_review_only == true and (.policy_reasons | index("temporary_implementation")) != null)' \
  "$TMP/state/queue/sidecars/"*.json >/dev/null
jq -se 'any(.[]; .review_kind == "person_identity" and .person_review_only == true and (.detected_names | index("Taylor Park")) != null)' \
  "$TMP/state/queue/sidecars/"*.json >/dev/null
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

# A discovered transcript can legitimately prefilter to no persona content.
# The empty branch must still finish receipts/metrics without referencing
# variables created only by the model-routing branch.
mkdir -p "$TMP/empty-chats/project"
printf '' > "$TMP/empty-chats/project/empty.jsonl"
touch -t "${SINCE//-/}1200" "$TMP/empty-chats/project/empty.jsonl"
DREAM_CLAUDE_PROJECTS_ROOT="$TMP/empty-chats" \
DREAM_CODEX_SESSIONS_ROOT="$TMP/empty-codex" \
"$RUNNER" --source claude --since "$SINCE" --shadow --keep-artifacts \
  --home "$TMP/empty-state" --config "$TMP/config.toml" --cwd "$TMP" \
  --codex-bin "$TMP/fake-codex" > "$TMP/empty-result.json"
EMPTY_RUN_ID=$(jq -er '.runs[0].run_id' "$TMP/empty-result.json")
jq -e '.runs[0].status == "shadow-complete" and .runs[0].transcripts == 1 and .runs[0].candidates == 0' \
  "$TMP/empty-result.json" >/dev/null
jq -e '(.status == "shadow-complete") and ([.stages.map,.stages.route,.stages.reconcile,.stages.apply] | all(.status == "success"))' \
  "$TMP/empty-state/runs/$EMPTY_RUN_ID/state.json" >/dev/null

# A validator failure must expose its real cause and retain stage counts instead
# of being masked by duplicate keyword arguments in stage_update().
if DREAM_TEST_INVALID_RECONCILE=1 "$RUNNER" --source claude --since "$SINCE" --shadow --keep-artifacts \
  --home "$TMP/invalid-state" --config "$TMP/config.toml" --cwd "$TMP" \
  --historical-current-review-days 0 \
  --codex-bin "$TMP/fake-codex" --map-concurrency 1 --route-concurrency 1 \
  --reconcile-concurrency 1 > "$TMP/invalid-result.json" 2> "$TMP/invalid-stderr.txt"; then
  echo "invalid reconcile run unexpectedly succeeded" >&2
  exit 1
fi
rg -Fq 'old_content must match exactly one complete line' "$TMP/invalid-stderr.txt"
INVALID_STATE=$(find "$TMP/invalid-state/runs" -name state.json -print -quit)
jq -e '.status == "failed" and .stages.reconcile.status == "failed" and .stages.reconcile.validation_failed == true and .stages.reconcile.total > 0' "$INVALID_STATE" >/dev/null

echo "test_dream_run_e2e: ok"
