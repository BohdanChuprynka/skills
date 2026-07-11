#!/usr/bin/env bash
# dream-skill — advance the last-run marker.
#
# Writes an ISO date or Unix epoch to source-specific marker file(s), unless dry-run is set.
# Existing markers are monotonic: a mixed-source run must not move a source that
# is already ahead back to an older batch boundary.
# I3: a dry-run is a zero-mutation preview — it must NEVER advance the marker, or
# the next real run would silently skip the previewed window (data loss). This
# guard lives in a script (not orchestrator prose) so it can be tested:
#   tests/test_advance_marker.sh
#
# Usage:
#   advance-marker.sh --date <YYYY-MM-DD> --run-state <state.json> [--dry-run] [--marker-dir <dir>] [--source claude|codex|all]
#   (default marker dir: $DREAM_MARKER_DIR, else ~/.claude/dream-skill)

set -uo pipefail
umask 077

die() { echo "advance-marker: $*" >&2; exit 1; }

DRY_RUN=0
SHADOW=0
DATE=""
MARKER_DIR="${DREAM_MARKER_DIR:-$HOME/.claude/dream-skill}"
SOURCE="${DREAM_TRANSCRIPT_SOURCE:-all}"
RUN_STATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --shadow)     SHADOW=1; shift ;;
    --date)       DATE="${2:-}"; shift 2 ;;
    --marker-dir) MARKER_DIR="${2:-}"; shift 2 ;;
    --source)     SOURCE="${2:-}"; shift 2 ;;
    --run-state)  RUN_STATE="${2:-}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

case "$SOURCE" in
  claude|codex|all) ;;
  "") die "--source requires one of: claude, codex, all" ;;
  *) die "invalid --source '$SOURCE' (expected claude, codex, or all)" ;;
esac

# I3: dry-run never touches the marker — exit before any write, even without --date.
if [ "$DRY_RUN" = "1" ]; then
  echo "advance-marker: dry-run — marker left unchanged"
  exit 0
fi

[ -n "$DATE" ] || die "missing --date (required on a real run)"
[ -n "$RUN_STATE" ] || die "missing --run-state; ungated marker advancement is forbidden"
[ -f "$RUN_STATE" ] || die "run state not found: $RUN_STATE"
command -v jq >/dev/null 2>&1 || die "jq required to validate run state"
jq -e --arg date "$DATE" --arg source "$SOURCE" --argjson shadow "$SHADOW" '
  . as $state
  | (if $shadow == 1
     then ($state.marker_allowed == false and $state.status == "shadow-complete")
     else ($state.marker_allowed == true and $state.status == "ready-to-advance")
     end)
  and (($state.marker_value // $state.window.end) == $date)
  and $state.source == $source
  and (["find","map","reduce","route","reconcile","apply","receipt"]
       | all(. as $stage | $state.stages[$stage].status == "success"))
' "$RUN_STATE" >/dev/null || die "run state does not authorize marker advancement"
mkdir -p "$MARKER_DIR" || die "cannot create marker dir: $MARKER_DIR"
chmod 700 "$MARKER_DIR" 2>/dev/null || true

LOCK_PATH="$MARKER_DIR/.marker.lock"
retries=100
while ! mkdir "$LOCK_PATH" 2>/dev/null; do
  holder=""
  [ -f "$LOCK_PATH/pid" ] && holder=$(cat "$LOCK_PATH/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$LOCK_PATH" 2>/dev/null || true
    continue
  fi
  retries=$((retries - 1))
  [ "$retries" -gt 0 ] || die "marker lock timeout: $MARKER_DIR"
  sleep 0.05
done
printf '%s\n' "$$" > "$LOCK_PATH/pid"
trap 'rm -rf "$LOCK_PATH" 2>/dev/null || true' EXIT

parse_marker_ts() {
  local value="$1"
  if printf '%s' "$value" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    date -j -f "%Y-%m-%d %H:%M:%S" "$value 00:00:00" +%s 2>/dev/null \
      || date -d "$value 00:00:00" +%s 2>/dev/null
  elif printf '%s' "$value" | grep -qE '^[0-9]+$'; then
    printf '%s\n' "$value"
  else
    return 1
  fi
}

new_ts=$(parse_marker_ts "$DATE") || die "cannot parse --date: $DATE"

write_marker() {
  local name="$1"
  local path="$MARKER_DIR/$name"
  local current current_ts
  if [ -f "$path" ]; then
    current=$(tr -d '[:space:]' < "$path" 2>/dev/null || true)
    if [ -n "$current" ] && current_ts=$(parse_marker_ts "$current" 2>/dev/null); then
      if [ "$new_ts" -lt "$current_ts" ]; then
        echo "advance-marker: $name kept at $current (candidate $DATE is older)"
        return 0
      fi
    fi
  fi
  local tmp
  tmp=$(mktemp "$MARKER_DIR/.${name}.tmp.XXXXXX") || die "cannot create marker temp file"
  printf '%s\n' "$DATE" > "$tmp" || { rm -f "$tmp"; die "cannot write marker temp: $tmp"; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" || { rm -f "$tmp"; die "cannot replace marker: $path"; }
  echo "advance-marker: $name -> $DATE"
}

case "$SOURCE" in
  claude) write_marker "last-run" ;;
  codex) write_marker "last-run-codex" ;;
  all)
    write_marker "last-run"
    write_marker "last-run-codex"
    ;;
esac
