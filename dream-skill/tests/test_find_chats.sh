#!/usr/bin/env bash
# Unit tests for find-chats.sh
# Uses DREAM_PROJECTS_ROOT to redirect away from real ~/.claude/projects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FINDER="$SCRIPT_DIR/../scripts/find-chats.sh"

[ -x "$FINDER" ] || { echo "FAIL: find-chats.sh missing or not executable"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

# ── fixture root ────────────────────────────────────────────────────────────
PROJ_ROOT=$(mktemp -d "/tmp/dream-projects-test-XXXXXX")
MARKER_DIR=$(mktemp -d "/tmp/dream-marker-test-XXXXXX")
trap 'rm -rf "$PROJ_ROOT" "$MARKER_DIR"' EXIT

# Helper: create a .jsonl file with an explicit mtime (days ago)
make_chat() {
  local path="$1" days_ago="$2"
  mkdir -p "$(dirname "$path")"
  echo '{"role":"user","content":"hello"}' > "$path"
  # macOS: touch -t [[CC]YY]MMDDhhmm[.ss]
  local ts
  ts=$(date -v "-${days_ago}d" +%Y%m%d%H%M 2>/dev/null \
    || date --date="${days_ago} days ago" +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

# ── test 1: default window (last 7 days) finds recent chats, skips old ───────
make_chat "$PROJ_ROOT/proj-a/aaa.jsonl" 3   # 3 days ago → inside window
make_chat "$PROJ_ROOT/proj-a/bbb.jsonl" 10  # 10 days ago → outside window

OUT=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
      DREAM_MARKER_DIR="$MARKER_DIR" \
      "$FINDER" 2>/dev/null)

echo "$OUT" | grep -q "aaa.jsonl" || fail "recent chat not included in default 7d window"
echo "$OUT" | grep -q "bbb.jsonl" && fail "old chat included in default 7d window (should be excluded)"
echo "PASS: default 7-day window"

# ── test 2: --since flag narrows/widens the window ───────────────────────────
SINCE=$(date -v "-5d" +%Y-%m-%d 2>/dev/null || date --date="5 days ago" +%Y-%m-%d)
OUT2=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" --since "$SINCE" 2>/dev/null)

echo "$OUT2" | grep -q "aaa.jsonl" || fail "--since: recent chat missing"
echo "$OUT2" | grep -q "bbb.jsonl" && fail "--since: old chat included when outside --since range"
echo "PASS: --since narrows window"

# ── test 3: --all emits BATCH headers and includes all chats ─────────────────
make_chat "$PROJ_ROOT/proj-b/old.jsonl" 30  # 30 days ago
OUT3=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" --all 2>/dev/null)

echo "$OUT3" | grep -q "^BATCH:" || fail "--all: no BATCH header emitted"
echo "$OUT3" | grep -q "old.jsonl" || fail "--all: 30-day-old chat not included"
echo "PASS: --all includes old chats + emits BATCH headers"

# ── test 4: --ignore'd chat is skipped ──────────────────────────────────────
IGNORE_CHAT="$PROJ_ROOT/proj-c/private.jsonl"
make_chat "$IGNORE_CHAT" 1
# Write a fake private-state.sh in a temp SKILL_HOME that always returns "ignore"
FAKE_HOME=$(mktemp -d "/tmp/dream-fakehome-XXXXXX")
mkdir -p "$FAKE_HOME/scripts"
printf '#!/usr/bin/env bash\necho "ignore"\n' > "$FAKE_HOME/scripts/private-state.sh"
chmod +x "$FAKE_HOME/scripts/private-state.sh"

OUT4=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       DREAM_SKILL_HOME="$FAKE_HOME" \
       "$FINDER" 2>/dev/null)
rm -rf "$FAKE_HOME"

echo "$OUT4" | grep -q "private.jsonl" && fail "--ignore'd chat was NOT skipped"
echo "PASS: --ignore'd chat is skipped"

# ── test 5: marker-based window — only chats newer than marker are included ──
MARKER_FILE_PATH="$MARKER_DIR/last-run"
# marker = 6 days ago: chat at 3d (inside) and chat at 10d (outside already made)
MARKER_DATE=$(date -v "-6d" +%Y-%m-%d 2>/dev/null || date --date="6 days ago" +%Y-%m-%d)
echo "$MARKER_DATE" > "$MARKER_FILE_PATH"

OUT5=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" 2>/dev/null)

echo "$OUT5" | grep -q "aaa.jsonl" || fail "marker window: recent chat missing"
echo "$OUT5" | grep -q "bbb.jsonl" && fail "marker window: old chat included"
rm -f "$MARKER_FILE_PATH"
echo "PASS: marker-based window"

# ── test 6: large window (>7 days --since) emits multiple BATCH headers ──────
SINCE_OLD=$(date -v "-20d" +%Y-%m-%d 2>/dev/null || date --date="20 days ago" +%Y-%m-%d)
OUT6=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" --since "$SINCE_OLD" 2>/dev/null)

BATCH_COUNT=$(echo "$OUT6" | grep -c "^BATCH:" || true)
[ "$BATCH_COUNT" -ge 2 ] || fail "large --since window: expected ≥2 BATCH headers, got $BATCH_COUNT"
echo "PASS: large window emits multiple BATCH headers"

# ── test 7: empty projects root returns single BATCH header, zero paths ───────
EMPTY_ROOT=$(mktemp -d "/tmp/dream-empty-XXXXXX")
OUT7=$(DREAM_PROJECTS_ROOT="$EMPTY_ROOT" \
       DREAM_MARKER_DIR="$MARKER_DIR" \
       "$FINDER" 2>/dev/null)
rm -rf "$EMPTY_ROOT"

echo "$OUT7" | grep -q "^BATCH:" || fail "empty root: BATCH header missing"
PATH_COUNT=$(echo "$OUT7" | grep -v "^BATCH:" | grep -c ".jsonl" || true)
[ "$PATH_COUNT" -eq 0 ] || fail "empty root: unexpected paths in output"
echo "PASS: empty projects root → BATCH header only"

# ── test 7b: corrupted marker → 7-day safe fallback (never epoch-0/all-history) ─
CORRUPT_MARKER_DIR=$(mktemp -d "/tmp/dream-corrupt-XXXXXX")
printf 'not-a-date\n' > "$CORRUPT_MARKER_DIR/last-run"
make_chat "$PROJ_ROOT/proj-e/recent.jsonl" 2  # 2 days ago → inside 7d window
make_chat "$PROJ_ROOT/proj-e/ancient.jsonl" 60  # 60 days ago → outside 7d window

OUT7B=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
        DREAM_MARKER_DIR="$CORRUPT_MARKER_DIR" \
        "$FINDER" 2>/dev/null)
rm -rf "$CORRUPT_MARKER_DIR"

# Corrupted marker must not return chats from 60 days ago (that would only happen
# if window_start fell back to epoch-0). It must return the 2-day-old chat.
echo "$OUT7B" | grep -q "recent.jsonl" || fail "corrupted marker: recent chat (2d) missing from 7d fallback window"
echo "$OUT7B" | grep -q "ancient.jsonl" && fail "corrupted marker: ancient chat (60d) included — epoch-0 fallback triggered (WRONG)"
echo "PASS: corrupted marker falls back to 7-day window, never epoch-0"

# ── test 8: marker written by orchestrator is read back on next invocation ───
MARKER_ROUNDTRIP_DIR=$(mktemp -d "/tmp/dream-marker-rt-XXXXXX")
# Simulate orchestrator advancing marker to 3 days ago
THREE_DAYS=$(date -v "-3d" +%Y-%m-%d 2>/dev/null || date --date="3 days ago" +%Y-%m-%d)
printf '%s\n' "$THREE_DAYS" > "$MARKER_ROUNDTRIP_DIR/last-run"

make_chat "$PROJ_ROOT/proj-d/new.jsonl" 1    # 1 day ago → inside marker window
make_chat "$PROJ_ROOT/proj-d/just-old.jsonl" 5  # 5 days ago → outside marker window (3d cutoff)

OUT8=$(DREAM_PROJECTS_ROOT="$PROJ_ROOT" \
       DREAM_MARKER_DIR="$MARKER_ROUNDTRIP_DIR" \
       "$FINDER" 2>/dev/null)
rm -rf "$MARKER_ROUNDTRIP_DIR"

echo "$OUT8" | grep -q "new.jsonl"      || fail "marker round-trip: recent chat missing"
echo "$OUT8" | grep -q "just-old.jsonl" && fail "marker round-trip: chat older than marker included"
echo "PASS: marker round-trip (orchestrator write → find-chats read)"

echo "All find-chats.sh tests passed."
