#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/queue/sidecars" "$TMP/runs" "$TMP/metrics"
printf '%s\n' '2026-07-09' > "$TMP/last-run"
printf '%s\n' '2026-07-09' > "$TMP/last-run-codex"
cat > "$TMP/queue/pending.md" <<'MD'
### Fact
**ID:** c-one
MD
printf '%s\n' '{"candidate_id":"c-one"}' > "$TMP/queue/sidecars/c-one.json"
printf '%s\n' '{"entries":[{"id":"c-one"}]}' > "$TMP/queue/review-input.json"
printf '%s\n' '{"run_id":"run-one","status":"completed","updated_at":"2026-07-09T12:00:00Z"}' > "$TMP/runs/run-one.json"
printf '%s\n' '{"run_id":"run-stale","status":"running","updated_at":"2026-07-09T13:00:00Z"}' > "$TMP/runs/run-stale.json"
printf '%s\n' "{\"run_id\":\"run-active\",\"status\":\"running\",\"attempt_pid\":$$,\"updated_at\":\"2026-07-09T14:00:00Z\"}" > "$TMP/runs/run-active.json"
chmod 755 "$TMP/queue"

python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" > "$TMP/health.json"
jq -e '.queue.pending_entries == 1 and .queue.orphan_pending == 0 and .queue.review_snapshot.exact_match == true and .privacy.unsafe_paths > 0 and .runs.active == 1 and .runs.stale == 1' "$TMP/health.json" >/dev/null
jq -e '.alerts | any(test("stale run state"))' "$TMP/health.json" >/dev/null

# A retained failed run should report the reusable and unresolved stage work,
# while a stale review snapshot must be visible before a reviewer acts on it.
cat >> "$TMP/queue/pending.md" <<'MD'

### Second fact
**ID:** c-two
MD
printf '%s\n' '{"candidate_id":"c-two"}' > "$TMP/queue/sidecars/c-two.json"
printf '%s\n' '{"entries":[{"id":"c-one"},{"id":"c-stale"}]}' > "$TMP/queue/review-input.json"
mkdir -p "$TMP/runs/run-failed"
cat > "$TMP/runs/run-failed/state.json" <<'JSON'
{
  "run_id":"run-failed",
  "status":"failed",
  "mode":"real",
  "updated_at":"2026-07-09T15:00:00Z",
  "stages":{"map":{"status":"failed","total":3,"completed":2,"failed":1}}
}
JSON
cat > "$TMP/runs/run-failed/map-run-summary.json" <<'JSON'
{"tasks":3,"completed":2,"failed":1,"error_classes":{"transport":1}}
JSON
python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" > "$TMP/failed-health.json"
jq -e '.runs.latest.run_id == "run-failed" and .runs.latest.recovery.failed_stage == "map" and .runs.latest.recovery.reusable_batches == 2 and .runs.latest.recovery.unresolved_batches == 1 and .runs.latest.recovery.error_classes.transport == 1' "$TMP/failed-health.json" >/dev/null
jq -e '.queue.review_snapshot.entries == 2 and .queue.review_snapshot.overlap == 1 and .queue.review_snapshot.stale_entries == 1 and .queue.review_snapshot.missing_live_entries == 1 and .queue.review_snapshot.exact_match == false' "$TMP/failed-health.json" >/dev/null
jq -e '.alerts | any(test("review snapshot"))' "$TMP/failed-health.json" >/dev/null
python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" --human > "$TMP/failed-health.txt"
rg -q 'Recovery: map, 2 reusable, 1 unresolved \(transport: 1\)' "$TMP/failed-health.txt"

python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" --fix-permissions > "$TMP/fixed.json"
[ "$(stat -c '%a' "$TMP/queue" 2>/dev/null || stat -f '%Lp' "$TMP/queue")" = "700" ]

echo "test_dream_health: ok"
