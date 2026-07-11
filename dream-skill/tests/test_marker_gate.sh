#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKER="$SKILL_DIR/scripts/advance-marker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/state.json" <<'JSON'
{
  "status":"ready-to-advance",
  "marker_allowed":true,
  "marker_value":"1783653000",
  "source":"all",
  "window":{"end":"2026-07-09"},
  "stages":{
    "find":{"status":"success"},
    "map":{"status":"success"},
    "reduce":{"status":"success"},
    "route":{"status":"success"},
    "reconcile":{"status":"success"},
    "apply":{"status":"success"},
    "receipt":{"status":"success"}
  }
}
JSON

if "$MARKER" --date 2026-07-09 --source all --marker-dir "$TMP/markers" >/dev/null 2>&1; then
  echo "ungated marker advancement unexpectedly succeeded" >&2
  exit 1
fi
"$MARKER" --date 1783653000 --source all --marker-dir "$TMP/markers" --run-state "$TMP/state.json" >/dev/null
[ "$(cat "$TMP/markers/last-run")" = "1783653000" ]
[ "$(cat "$TMP/markers/last-run-codex")" = "1783653000" ]

jq '.stages.map.status = "failed"' "$TMP/state.json" > "$TMP/bad.json"
if "$MARKER" --date 2026-07-10 --source all --marker-dir "$TMP/markers" --run-state "$TMP/bad.json" >/dev/null 2>&1; then
  echo "failed run unexpectedly advanced marker" >&2
  exit 1
fi
[ "$(cat "$TMP/markers/last-run")" = "1783653000" ]

"$MARKER" --dry-run --source all --marker-dir "$TMP/markers" >/dev/null
[ "$(cat "$TMP/markers/last-run")" = "1783653000" ]

jq '.status = "shadow-complete" | .marker_allowed = false' "$TMP/state.json" > "$TMP/shadow.json"
"$MARKER" --shadow --date 1783653000 --source all --marker-dir "$TMP/shadow-markers" --run-state "$TMP/shadow.json" >/dev/null
[ "$(cat "$TMP/shadow-markers/last-run")" = "1783653000" ]

echo "test_marker_gate: ok"
