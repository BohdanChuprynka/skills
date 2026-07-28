#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/queue/sidecars" "$TMP/runs" "$TMP/metrics" "$TMP/raw"

printf '%s\n' '2026-07-19' > "$TMP/last-run"
printf '%s\n' '2026-07-19' > "$TMP/last-run-codex"
printf '%s\n' '{"run_id":"run-old","status":"completed","mode":"real","updated_at":"2026-07-19T12:00:00Z"}' > "$TMP/runs/run-old.json"
printf '%s\n' '## As of 2026-07-03' > "$TMP/Now.md"
printf '%s\n' 'fresh source' > "$TMP/raw/wispr.jsonl"
cat > "$TMP/config.toml" <<TOML
[health]
expected_cadence_days = 7
cadence_grace_days = 1
current_page_stale_days = 7
current_pages = ["$TMP/Now.md"]
source_paths = ["$TMP/raw/*.jsonl"]
TOML

python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" > "$TMP/health.json"
jq -e '.cadence.latest_real_run.run_id == "run-old"' "$TMP/health.json" >/dev/null
jq -e '.cadence.stale_production_run == true' "$TMP/health.json" >/dev/null
jq -e '.cadence.source_backlogs | length == 1' "$TMP/health.json" >/dev/null
jq -e '.current_pages.findings | any(.signal == "stale_as_of")' "$TMP/health.json" >/dev/null
jq -e '.alerts | any(test("stale production cadence"))' "$TMP/health.json" >/dev/null

echo "test_health_cadence: ok"
