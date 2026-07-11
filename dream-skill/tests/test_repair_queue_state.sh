#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/queue/sidecars"
cat > "$TMP/queue/pending.md" <<'MD'
### Keep
**ID:** c-keep
---
### Legacy
**ID:** c-legacy
---
MD
printf '%s\n' '{"candidate_id":"c-keep"}' > "$TMP/queue/sidecars/c-keep.json"
printf '%s\n' '{"candidate_id":"c-orphan"}' > "$TMP/queue/sidecars/c-orphan.json"
printf '%s\n' '{"c-keep":"approve","c-legacy":"reject"}' > "$TMP/queue/review-decisions.json"
printf '%s\n' '{"entries":[{"id":"c-keep"},{"id":"c-legacy"}]}' > "$TMP/queue/review-input.json"

python3 "$SKILL_DIR/scripts/repair-queue-state.py" --home "$TMP" --apply --archive-name test > "$TMP/report.json"
jq -e '.applyable == 1 and .orphan_pending == 1 and .orphan_sidecars == 1' "$TMP/report.json" >/dev/null
rg -q 'c-keep' "$TMP/queue/pending.md"
! rg -q 'c-legacy' "$TMP/queue/pending.md"
jq -e 'keys == ["c-keep"]' "$TMP/queue/review-decisions.json" >/dev/null
[ -f "$TMP/queue/archive/test/pending.md" ]
[ ! -f "$TMP/queue/sidecars/c-orphan.json" ]

echo "test_repair_queue_state: ok"
