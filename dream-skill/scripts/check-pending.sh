#!/usr/bin/env bash
# dream-skill orphan scanner. Runs as SessionStart hook.
# Reads trigger.log; for each SPAWNED line outside the grace window,
# checks for a matching COMPLETED / ERROR / WARNING. Orphans → append
# WARNING line. Idempotent — once a WARNING exists for a transcript,
# we never duplicate it. Outputs nothing to stdout (zero context cost).
# Always exits 0 — never break SessionStart.

set -uo pipefail   # NOT -e — never propagate failure

LOG="${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}"
GRACE_SEC="${DREAM_ORPHAN_GRACE_SEC:-300}"     # 5 min default
WINDOW_SEC="${DREAM_ORPHAN_WINDOW_SEC:-3600}"  # 1h lookback default

[ -f "$LOG" ] || exit 0
command -v awk >/dev/null 2>&1 || exit 0

NOW=$(date +%s)
WINDOW_CUTOFF=$((NOW - WINDOW_SEC))
GRACE_CUTOFF=$((NOW - GRACE_SEC))

# Parse epoch from ISO-8601 UTC timestamp (cross-platform: BSD vs GNU date)
to_epoch() {
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || echo 0
}

# Collect SPAWNED records: "<iso_ts> <transcript_path>"
SPAWNS=$(mktemp "/tmp/dream-spawns-XXXXXX")
COMPLETIONS=$(mktemp "/tmp/dream-completions-XXXXXX")
WARNED=$(mktemp "/tmp/dream-warned-XXXXXX")
trap 'rm -f "$SPAWNS" "$COMPLETIONS" "$WARNED"' EXIT

awk '/SPAWNED/ {
  ts = $1
  for (i = 2; i <= NF; i++) {
    if ($i ~ /^transcript=/) {
      sub(/^transcript=/, "", $i)
      print ts " " $i
    }
  }
}' "$LOG" > "$SPAWNS" 2>/dev/null || true

# COMPLETED or ERROR lines — both represent "spawn resolved"
awk '/COMPLETED|ERROR/ {
  for (i = 2; i <= NF; i++) {
    if ($i ~ /^transcript=/) {
      sub(/^transcript=/, "", $i)
      print $i
    }
  }
}' "$LOG" > "$COMPLETIONS" 2>/dev/null || true

# Existing WARNING orphan lines — for dedupe
awk '/WARNING kind=orphan/ {
  for (i = 2; i <= NF; i++) {
    if ($i ~ /^transcript=/) {
      sub(/^transcript=/, "", $i)
      print $i
    }
  }
}' "$LOG" > "$WARNED" 2>/dev/null || true

# For each SPAWNED: decide orphan vs not
while IFS=' ' read -r SP_TS SP_PATH; do
  [ -n "${SP_PATH:-}" ] || continue

  SP_EPOCH=$(to_epoch "$SP_TS")
  [ "$SP_EPOCH" -gt 0 ] || continue
  [ "$SP_EPOCH" -gt "$WINDOW_CUTOFF" ] || continue   # outside lookback window
  [ "$SP_EPOCH" -lt "$GRACE_CUTOFF" ] || continue    # within grace, skip

  # Already resolved by COMPLETED or ERROR?
  grep -Fxq "$SP_PATH" "$COMPLETIONS" 2>/dev/null && continue
  # Already warned about?
  grep -Fxq "$SP_PATH" "$WARNED" 2>/dev/null && continue

  # Orphan: append WARNING line to the log
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$TS WARNING kind=orphan transcript=$SP_PATH spawned-at=$SP_TS" >> "$LOG"
done < "$SPAWNS"

exit 0
