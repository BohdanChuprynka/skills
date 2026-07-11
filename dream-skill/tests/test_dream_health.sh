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
printf '%s\n' '{"run_id":"run-one","status":"completed","updated_at":"2026-07-09T12:00:00Z"}' > "$TMP/runs/run-one.json"
chmod 755 "$TMP/queue"

python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" > "$TMP/health.json"
jq -e '.queue.pending_entries == 1 and .queue.orphan_pending == 0 and .privacy.unsafe_paths > 0' "$TMP/health.json" >/dev/null
python3 "$SKILL_DIR/scripts/dream-health.py" --home "$TMP" --fix-permissions > "$TMP/fixed.json"
[ "$(stat -f '%Lp' "$TMP/queue" 2>/dev/null || stat -c '%a' "$TMP/queue")" = "700" ]

echo "test_dream_health: ok"
