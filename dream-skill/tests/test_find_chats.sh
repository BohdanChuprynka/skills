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
CODEX_ROOT=$(mktemp -d "/tmp/dream-codex-sessions-test-XXXXXX")
MARKER_DIR=$(mktemp -d "/tmp/dream-marker-test-XXXXXX")
trap 'rm -rf "$PROJ_ROOT" "$CODEX_ROOT" "$MARKER_DIR"' EXIT

# Helper: assign an explicit mtime (days ago)
set_mtime_days_ago() {
  local path="$1" days_ago="$2"
  # macOS: touch -t [[CC]YY]MMDDhhmm[.ss]
  local ts
  ts=$(date -v "-${days_ago}d" +%Y%m%d%H%M 2>/dev/null \
    || date --date="${days_ago} days ago" +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

# Helper: create a Claude-style .jsonl file with an explicit mtime (days ago)
make_chat() {
  local path="$1" days_ago="$2"
  mkdir -p "$(dirname "$path")"
  echo '{"role":"user","content":"hello"}' > "$path"
  set_mtime_days_ago "$path" "$days_ago"
}

# Helper: create a Codex-style .jsonl file with an explicit mtime (days ago)
make_codex_chat() {
  local path="$1" days_ago="$2" thread_source="${3:-user}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{"timestamp":"2026-07-01T00:00:00Z","type":"session_meta","payload":{"id":"s1","thread_source":"$thread_source","originator":"codex-tui"}}
{"timestamp":"2026-07-01T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello from codex"}}
EOF
  set_mtime_days_ago "$path" "$days_ago"
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

# ── test 9 (C2): early-morning chat on the boundary day is NOT silently dropped ──
# Regression for bare-date parsing. BSD `date -j -f "%Y-%m-%d" "$d" +%s` fills H:M:S
# from the wall clock, so window_start landed at ~now's time-of-day on the boundary
# day and a 00:01 chat there was dropped on any later-in-day run. window_start MUST
# anchor to midnight. Exercises BOTH the marker branch and the --since branch.
BND_PROJ=$(mktemp -d "/tmp/dream-bnd-proj-XXXXXX")
BND_MARKER=$(mktemp -d "/tmp/dream-bnd-marker-XXXXXX")
BD_COMPACT=$(date -v "-4d" +%Y%m%d 2>/dev/null || date --date="4 days ago" +%Y%m%d)
BD_DATE=$(date -v "-4d" +%Y-%m-%d 2>/dev/null || date --date="4 days ago" +%Y-%m-%d)
EARLY="$BND_PROJ/proj-bnd/early.jsonl"
mkdir -p "$(dirname "$EARLY")"
echo '{"role":"user","content":"hi"}' > "$EARLY"
touch -t "${BD_COMPACT}0001" "$EARLY"   # boundary day at 00:01

printf '%s\n' "$BD_DATE" > "$BND_MARKER/last-run"
OUT9M=$(DREAM_PROJECTS_ROOT="$BND_PROJ" DREAM_MARKER_DIR="$BND_MARKER" "$FINDER" 2>/dev/null)
echo "$OUT9M" | grep -q "early.jsonl" \
  || fail "C2 marker branch: 00:01 boundary-day chat dropped (window_start not anchored to midnight)"

OUT9S=$(DREAM_PROJECTS_ROOT="$BND_PROJ" DREAM_MARKER_DIR="$BND_MARKER" "$FINDER" --since "$BD_DATE" 2>/dev/null)
echo "$OUT9S" | grep -q "early.jsonl" \
  || fail "C2 --since branch: 00:01 boundary-day chat dropped (window_start not anchored to midnight)"

rm -rf "$BND_PROJ" "$BND_MARKER"
echo "PASS: early-morning boundary-day chat retained (C2 midnight-anchor regression guard)"

# ── test 10: source selector supports Codex without changing Claude default ─────
SOURCE_PROJ=$(mktemp -d "/tmp/dream-source-proj-XXXXXX")
SOURCE_CODEX=$(mktemp -d "/tmp/dream-source-codex-XXXXXX")
SOURCE_MARKER=$(mktemp -d "/tmp/dream-source-marker-XXXXXX")
make_chat "$SOURCE_PROJ/proj-src/claude.jsonl" 1
make_codex_chat "$SOURCE_CODEX/2026/07/01/codex.jsonl" 1
make_codex_chat "$SOURCE_CODEX/2026/07/01/codex-subagent.jsonl" 1 "subagent"

OUT10_DEFAULT=$(DREAM_PROJECTS_ROOT="$SOURCE_PROJ" \
                DREAM_CODEX_SESSIONS_ROOT="$SOURCE_CODEX" \
                DREAM_MARKER_DIR="$SOURCE_MARKER" \
                "$FINDER" 2>/dev/null)
echo "$OUT10_DEFAULT" | grep -q "claude.jsonl" || fail "source default: Claude chat missing"
echo "$OUT10_DEFAULT" | grep -q "codex.jsonl" && fail "source default: Codex chat included without --source codex/all"

OUT10_CODEX=$(DREAM_PROJECTS_ROOT="$SOURCE_PROJ" \
              DREAM_CODEX_SESSIONS_ROOT="$SOURCE_CODEX" \
              DREAM_MARKER_DIR="$SOURCE_MARKER" \
              "$FINDER" --source codex 2>/dev/null)
echo "$OUT10_CODEX" | grep -q "codex.jsonl" || fail "--source codex: Codex chat missing"
echo "$OUT10_CODEX" | grep -q "claude.jsonl" && fail "--source codex: Claude chat included"
echo "$OUT10_CODEX" | grep -q "codex-subagent.jsonl" && fail "--source codex: Codex subagent chat included"

OUT10_ALL=$(DREAM_PROJECTS_ROOT="$SOURCE_PROJ" \
            DREAM_CODEX_SESSIONS_ROOT="$SOURCE_CODEX" \
            DREAM_MARKER_DIR="$SOURCE_MARKER" \
            "$FINDER" --source all 2>/dev/null)
echo "$OUT10_ALL" | grep -q "claude.jsonl" || fail "--source all: Claude chat missing"
echo "$OUT10_ALL" | grep -q "codex.jsonl" || fail "--source all: Codex chat missing"
echo "$OUT10_ALL" | grep -q "codex-subagent.jsonl" && fail "--source all: Codex subagent chat included"

OUT10_ENV=$(DREAM_TRANSCRIPT_SOURCE=codex \
            DREAM_PROJECTS_ROOT="$SOURCE_PROJ" \
            DREAM_CODEX_SESSIONS_ROOT="$SOURCE_CODEX" \
            DREAM_MARKER_DIR="$SOURCE_MARKER" \
            "$FINDER" 2>/dev/null)
echo "$OUT10_ENV" | grep -q "codex.jsonl" || fail "DREAM_TRANSCRIPT_SOURCE=codex: Codex chat missing"
echo "$OUT10_ENV" | grep -q "claude.jsonl" && fail "DREAM_TRANSCRIPT_SOURCE=codex: Claude chat included"

OUT10_ALIAS=$(DREAM_CLAUDE_PROJECTS_ROOT="$SOURCE_PROJ" \
              DREAM_CODEX_SESSIONS_ROOT="$SOURCE_CODEX" \
              DREAM_MARKER_DIR="$SOURCE_MARKER" \
              "$FINDER" --source claude 2>/dev/null)
echo "$OUT10_ALIAS" | grep -q "claude.jsonl" || fail "DREAM_CLAUDE_PROJECTS_ROOT alias did not scan Claude root"

rm -rf "$SOURCE_PROJ" "$SOURCE_CODEX" "$SOURCE_MARKER"
echo "PASS: source selector supports Claude, Codex, all, env default, and Codex subagent exclusion"

# ── test 11: Codex source uses a source-specific marker ──────────────────────
SRC_MARKER_PROJ=$(mktemp -d "/tmp/dream-src-marker-proj-XXXXXX")
SRC_MARKER_CODEX=$(mktemp -d "/tmp/dream-src-marker-codex-XXXXXX")
SRC_MARKER_DIR=$(mktemp -d "/tmp/dream-src-marker-dir-XXXXXX")
make_chat "$SRC_MARKER_PROJ/proj-src-marker/claude-three-days.jsonl" 3
make_codex_chat "$SRC_MARKER_CODEX/2026/07/01/codex-three-days.jsonl" 3
ONE_DAY=$(date -v "-1d" +%Y-%m-%d 2>/dev/null || date --date="1 day ago" +%Y-%m-%d)
FIVE_DAYS=$(date -v "-5d" +%Y-%m-%d 2>/dev/null || date --date="5 days ago" +%Y-%m-%d)
printf '%s\n' "$ONE_DAY" > "$SRC_MARKER_DIR/last-run"
printf '%s\n' "$FIVE_DAYS" > "$SRC_MARKER_DIR/last-run-codex"

OUT11_CODEX=$(DREAM_PROJECTS_ROOT="$SRC_MARKER_PROJ" \
              DREAM_CODEX_SESSIONS_ROOT="$SRC_MARKER_CODEX" \
              DREAM_MARKER_DIR="$SRC_MARKER_DIR" \
              "$FINDER" --source codex 2>/dev/null)
echo "$OUT11_CODEX" | grep -q "codex-three-days.jsonl" \
  || fail "--source codex should use last-run-codex, not the newer Claude last-run marker"

OUT11_CLAUDE=$(DREAM_PROJECTS_ROOT="$SRC_MARKER_PROJ" \
               DREAM_CODEX_SESSIONS_ROOT="$SRC_MARKER_CODEX" \
               DREAM_MARKER_DIR="$SRC_MARKER_DIR" \
               "$FINDER" --source claude 2>/dev/null)
echo "$OUT11_CLAUDE" | grep -q "claude-three-days.jsonl" \
  && fail "--source claude should use last-run and exclude 3-day-old Claude chat"

OUT11_ALL=$(DREAM_PROJECTS_ROOT="$SRC_MARKER_PROJ" \
            DREAM_CODEX_SESSIONS_ROOT="$SRC_MARKER_CODEX" \
            DREAM_MARKER_DIR="$SRC_MARKER_DIR" \
            "$FINDER" --source all 2>/dev/null)
echo "$OUT11_ALL" | grep -q "codex-three-days.jsonl" \
  || fail "--source all should use the oldest source marker and include unprocessed Codex chat"

rm -f "$SRC_MARKER_DIR/last-run-codex"
OUT11_ALL_MISSING_CODEX=$(DREAM_PROJECTS_ROOT="$SRC_MARKER_PROJ" \
                          DREAM_CODEX_SESSIONS_ROOT="$SRC_MARKER_CODEX" \
                          DREAM_MARKER_DIR="$SRC_MARKER_DIR" \
                          "$FINDER" --source all 2>/dev/null)
echo "$OUT11_ALL_MISSING_CODEX" | grep -q "codex-three-days.jsonl" \
  || fail "--source all should not let an initialized Claude marker skip a missing Codex marker"

rm -rf "$SRC_MARKER_PROJ" "$SRC_MARKER_CODEX" "$SRC_MARKER_DIR"
echo "PASS: source-specific markers prevent cross-source skips"

# ── test 12: --since with missing date argument → non-zero exit ──────────────
RC10=0
DREAM_PROJECTS_ROOT="$PROJ_ROOT" DREAM_MARKER_DIR="$MARKER_DIR" \
  "$FINDER" --since >/dev/null 2>&1 || RC10=$?
[ "$RC10" -ne 0 ] || fail "--since with no date: expected non-zero exit, got exit 0"
echo "PASS: --since with missing date argument → non-zero exit"

RC12=0
DREAM_PROJECTS_ROOT="$PROJ_ROOT" DREAM_MARKER_DIR="$MARKER_DIR" \
  "$FINDER" --source nope >/dev/null 2>&1 || RC12=$?
[ "$RC12" -ne 0 ] || fail "--source with invalid source should exit non-zero"
echo "PASS: invalid --source value → non-zero exit"

echo "All find-chats.sh tests passed."
