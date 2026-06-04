#!/usr/bin/env bash
# dream-skill — advance the last-run marker.
#
# Writes <date> to <marker-dir>/last-run, UNLESS --dry-run is set.
# I3: a dry-run is a zero-mutation preview — it must NEVER advance the marker, or
# the next real run would silently skip the previewed window (data loss). This
# guard lives in a script (not orchestrator prose) so it can be tested:
#   tests/test_advance_marker.sh
#
# Usage:
#   advance-marker.sh --date <YYYY-MM-DD> [--dry-run] [--marker-dir <dir>]
#   (default marker dir: $DREAM_MARKER_DIR, else ~/.claude/dream-skill)

set -uo pipefail

die() { echo "advance-marker: $*" >&2; exit 1; }

DRY_RUN=0
DATE=""
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --date)       DATE="${2:-}"; shift 2 ;;
    --marker-dir) MARKER_DIR="${2:-}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# I3: dry-run never touches the marker — exit before any write, even without --date.
if [ "$DRY_RUN" = "1" ]; then
  echo "advance-marker: dry-run — marker left unchanged"
  exit 0
fi

[ -n "$DATE" ] || die "missing --date (required on a real run)"
mkdir -p "$MARKER_DIR" || die "cannot create marker dir: $MARKER_DIR"
printf '%s\n' "$DATE" > "$MARKER_DIR/last-run" || die "cannot write marker: $MARKER_DIR/last-run"
echo "advance-marker: last-run -> $DATE"
