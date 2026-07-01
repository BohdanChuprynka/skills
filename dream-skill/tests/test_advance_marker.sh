#!/usr/bin/env bash
# Test: advance-marker.sh — writes last-run marker, but NEVER on --dry-run (I3).
# I3 is a data-loss guard: a dry-run that advanced the marker would make the next
# real run skip the previewed window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARKER="$SCRIPT_DIR/../scripts/advance-marker.sh"
[ -x "$MARKER" ] || { echo "FAIL: advance-marker.sh missing or not executable"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

MDIR=$(mktemp -d "/tmp/dream-marker-test-XXXXXX")
trap 'rm -rf "$MDIR"' EXIT

# Test 1: a real default run advances both source markers
"$MARKER" --date "2026-06-04" --marker-dir "$MDIR" >/dev/null
[ -f "$MDIR/last-run" ] || fail "real run did not create the marker"
[ -f "$MDIR/last-run-codex" ] || fail "real run did not create the Codex marker"
[ "$(cat "$MDIR/last-run")" = "2026-06-04" ] || fail "marker content wrong: $(cat "$MDIR/last-run")"
[ "$(cat "$MDIR/last-run-codex")" = "2026-06-04" ] || fail "Codex marker content wrong: $(cat "$MDIR/last-run-codex")"
echo "PASS: default real run advances both source markers to the date"

# Test 2: --dry-run does NOT create a marker (fresh dir) — I3
DRYDIR=$(mktemp -d "/tmp/dream-marker-dry-XXXXXX")
"$MARKER" --date "2026-06-04" --marker-dir "$DRYDIR" --dry-run >/dev/null
[ -f "$DRYDIR/last-run" ] && { rm -rf "$DRYDIR"; fail "I3 VIOLATION: --dry-run created the marker file"; }
[ -f "$DRYDIR/last-run-codex" ] && { rm -rf "$DRYDIR"; fail "I3 VIOLATION: --dry-run created the Codex marker file"; }
rm -rf "$DRYDIR"
echo "PASS: --dry-run does not create the marker (I3)"

# Test 3: --dry-run does NOT advance an EXISTING marker — the data-loss case (I3)
printf '2026-05-20\n' > "$MDIR/last-run"
printf '2026-05-21\n' > "$MDIR/last-run-codex"
BEFORE=$(shasum -a 256 "$MDIR/last-run" | awk '{print $1}')
BEFORE_CODEX=$(shasum -a 256 "$MDIR/last-run-codex" | awk '{print $1}')
"$MARKER" --date "2026-06-04" --marker-dir "$MDIR" --dry-run >/dev/null
AFTER=$(shasum -a 256 "$MDIR/last-run" | awk '{print $1}')
AFTER_CODEX=$(shasum -a 256 "$MDIR/last-run-codex" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "I3 VIOLATION: --dry-run advanced an existing marker"
[ "$BEFORE_CODEX" = "$AFTER_CODEX" ] || fail "I3 VIOLATION: --dry-run advanced an existing Codex marker"
[ "$(cat "$MDIR/last-run")" = "2026-05-20" ] || fail "I3: existing marker changed under dry-run"
[ "$(cat "$MDIR/last-run-codex")" = "2026-05-21" ] || fail "I3: existing Codex marker changed under dry-run"
echo "PASS: --dry-run leaves an existing marker byte-identical (I3)"

# Test 4: a real default run advances existing source markers
"$MARKER" --date "2026-06-04" --marker-dir "$MDIR" >/dev/null
[ "$(cat "$MDIR/last-run")" = "2026-06-04" ] || fail "real run did not advance an existing marker"
[ "$(cat "$MDIR/last-run-codex")" = "2026-06-04" ] || fail "real run did not advance an existing Codex marker"
echo "PASS: default real run advances existing source markers"

# Test 5: missing --date on a real run fails loudly (no silent empty marker)
if "$MARKER" --marker-dir "$MDIR" 2>/dev/null; then
  fail "missing --date should exit non-zero on a real run"
fi
echo "PASS: missing --date fails on a real run"

# Test 6: --dry-run without --date is still a safe no-op (exit 0)
"$MARKER" --marker-dir "$MDIR" --dry-run >/dev/null || fail "--dry-run should exit 0 even without --date"
echo "PASS: --dry-run is a safe no-op even without --date"

# Test 7: Codex source writes last-run-codex without touching Claude marker
printf '2026-06-01\n' > "$MDIR/last-run"
"$MARKER" --date "2026-06-10" --marker-dir "$MDIR" --source codex >/dev/null
[ "$(cat "$MDIR/last-run")" = "2026-06-01" ] || fail "--source codex should not touch Claude last-run marker"
[ "$(cat "$MDIR/last-run-codex")" = "2026-06-10" ] || fail "--source codex did not write last-run-codex"
echo "PASS: Codex source advances only last-run-codex"

# Test 8: all source advances both source markers
"$MARKER" --date "2026-06-11" --marker-dir "$MDIR" --source all >/dev/null
[ "$(cat "$MDIR/last-run")" = "2026-06-11" ] || fail "--source all did not advance Claude marker"
[ "$(cat "$MDIR/last-run-codex")" = "2026-06-11" ] || fail "--source all did not advance Codex marker"
echo "PASS: all source advances both source markers"

# Test 9: all source never moves an already-newer marker backward
printf '2026-07-01\n' > "$MDIR/last-run"
printf '2026-06-01\n' > "$MDIR/last-run-codex"
"$MARKER" --date "2026-06-08" --marker-dir "$MDIR" --source all >/dev/null
[ "$(cat "$MDIR/last-run")" = "2026-07-01" ] || fail "--source all moved Claude marker backward"
[ "$(cat "$MDIR/last-run-codex")" = "2026-06-08" ] || fail "--source all did not advance older Codex marker"
"$MARKER" --date "2026-07-08" --marker-dir "$MDIR" --source all >/dev/null
[ "$(cat "$MDIR/last-run")" = "2026-07-08" ] || fail "--source all did not advance Claude marker after catch-up"
[ "$(cat "$MDIR/last-run-codex")" = "2026-07-08" ] || fail "--source all did not advance Codex marker after catch-up"
echo "PASS: all source marker advancement is monotonic per source"

echo
echo "All advance-marker.sh tests passed."
