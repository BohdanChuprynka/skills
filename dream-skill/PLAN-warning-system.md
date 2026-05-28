# Failure-Logging System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface every dream-skill outcome (success, legitimate skip, failure) in `~/.claude/dream-skill/trigger.log` as structured one-line records. No popups, no Claude-context injection, no extra files. User reads the log when they want.

**Architecture:**
1. `trigger.log` is the single source of truth. Append-only. Six line types: `SKIP`, `DISPATCH`, `SPAWNED`, `COMPLETED`, `ERROR`, `WARNING`.
2. `trigger.sh` wraps the background `claude -p` spawn to catch the exit code → writes `COMPLETED` on exit 0, `ERROR` on non-zero.
3. `SKILL.md` auto-mode appends a `COMPLETED` or `ERROR` marker to `trigger.log` at every exit branch.
4. New `check-pending.sh` runs as `SessionStart` hook — scans `trigger.log` for orphan `SPAWNED` lines (no matching `COMPLETED`/`ERROR`/`WARNING`) older than 5 min → appends a `WARNING orphan-detected` line. Once an orphan has a `WARNING` line, future scans skip it (idempotent — no log spam).
5. **No notifications. No popups. No context injection.** Everything is `tail ~/.claude/dream-skill/trigger.log`.

**Tech Stack:** Bash, `awk` for log parsing, Claude Code SessionStart hook, atomic append.

---

## Data contract — `trigger.log` line formats

Single file: `${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}`. Append-only. Each dispatch produces at minimum a `SPAWNED` line and exactly one of `COMPLETED` / `ERROR`. Optional `WARNING` line if check-pending detects an orphan.

| Line prefix | When | Source | Fields |
|---|---|---|---|
| `SKIP` | trigger.sh skips dispatch (below-threshold, no-path, duplicate, reason=clear, etc.) | trigger.sh | `reason=<short>` |
| `DISPATCH` | trigger.sh decides to spawn | trigger.sh | `count=N threshold=N transcript=<path> reason=<close-reason>` |
| `SPAWNED` | background wrapper started `claude -p` | trigger.sh | `pid=N model=<name> transcript=<path>` |
| `COMPLETED` | SKILL.md auto-mode finished cleanly OR `claude -p` exited 0 | SKILL.md + wrapper | `source=<skill\|claude-p> reason=<status> writes=N queued=N dropped=N transcript=<path>` |
| `ERROR` | trigger.sh pre-flight failure OR `claude -p` non-zero exit OR SKILL.md internal error | trigger.sh + SKILL.md | `source=<trigger\|claude-p\|skill> code=N msg="..." transcript=<path>` |
| `WARNING` | check-pending.sh detected an orphan `SPAWNED` | check-pending.sh | `kind=orphan transcript=<path> spawned-at=<ts>` |

**Orphan rule:** A `SPAWNED transcript=X` line with no matching `COMPLETED transcript=X`, no matching `ERROR transcript=X`, no matching `WARNING ... transcript=X`, AND timestamp > 5 minutes ago → orphan candidate. Append `WARNING kind=orphan ...`. The grace window prevents flagging spawns that are still legitimately running.

To inspect:

```bash
tail ~/.claude/dream-skill/trigger.log              # last 10 events
grep -E "ERROR|WARNING" ~/.claude/dream-skill/trigger.log   # all failures
grep "WARNING kind=orphan" ~/.claude/dream-skill/trigger.log  # silent aborts
```

---

## File structure (final)

```
dream-skill/
├── scripts/
│   ├── trigger.sh                  # MODIFY: wrapped spawn, ERROR/COMPLETED markers
│   └── check-pending.sh            # NEW: SessionStart hook — orphan scanner, appends WARNING
├── hooks/
│   └── hooks.json                  # MODIFY: register SessionStart hook
├── skills/dream-skill/
│   └── SKILL.md                    # MODIFY: auto-mode appends COMPLETED/ERROR to trigger.log
├── tests/
│   ├── test_trigger.sh             # EXTEND: claude-p exit-code wrapper case
│   ├── test_check_pending.sh       # NEW: orphan detection + dedupe via WARNING
│   └── fixtures/
│       ├── trigger-log-orphan.txt          # NEW: SPAWNED with no completion
│       ├── trigger-log-completed.txt       # NEW: SPAWNED + matching COMPLETED
│       ├── trigger-log-errored.txt         # NEW: SPAWNED + matching ERROR
│       └── trigger-log-already-warned.txt  # NEW: orphan + existing WARNING line
└── README.md                       # MODIFY: FAQ entry + Safety bullet (logs-only)
```

---

## Task list

### Task 1: trigger.sh wraps `claude -p` spawn + writes ERROR line on every error path

**Files:**
- Modify: `dream-skill/scripts/trigger.sh`
- Extend: `dream-skill/tests/test_trigger.sh`

**Behavior contract:**
- Every existing `log "ERROR ..."` path stays — these are already logged. No notification call added.
- The final `claude -p` spawn gets wrapped in a subshell that captures the exit code:
  - exit 0 → append `COMPLETED source=claude-p transcript=...` to `$DREAM_LOG`
  - exit non-zero → append `ERROR source=claude-p code=$RC transcript=...` to `$DREAM_LOG`
- Backgrounded, fire-and-forget, never blocks trigger.sh from returning to Claude Code.

- [ ] **Step 1: Update existing ERROR paths to use the new `source=` field format**

Find the existing claude-cli-missing path:

```bash
# Before:
if ! command -v claude >/dev/null 2>&1; then
  log "ERROR claude-cli-missing"
  exit 0
fi

# After (more structured for grep-ability):
if ! command -v claude >/dev/null 2>&1; then
  log "ERROR source=trigger code=127 msg=claude-cli-missing"
  exit 0
fi
```

Also update the trap:

```bash
on_exit() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "ERROR source=trigger code=$rc msg=trap-fired"
  fi
  exit 0
}
trap on_exit EXIT
```

Legitimate SKIP paths (`file-not-found`, `no-path-provided`, `below-threshold`, `duplicate-dispatch`, `reason=clear`, etc.) keep their `SKIP` prefix — they are NOT failures.

- [ ] **Step 2: Replace bare background spawn with wrapped subshell**

Find the existing block (around lines 144-150):

```bash
# Replace this:
nohup claude -p \
  --model "$MODEL" \
  --dangerously-skip-permissions \
  "/dream-skill --auto $TRANSCRIPT" \
  >> "$(dirname "$LOG_FILE")/headless.log" 2>&1 &
disown
log "SPAWNED pid=$! model=$MODEL scripts=$SCRIPTS_DIR"
```

with:

```bash
# Background wrapper: spawn, await exit, append COMPLETED/ERROR to trigger.log.
# Outer `nohup ... &` keeps trigger.sh fire-and-forget (it returns immediately).
# Inner block is the wait-and-report logic. No notifications — logs only.
nohup bash -c "
  claude -p \\
    --model '$MODEL' \\
    --dangerously-skip-permissions \\
    '/dream-skill --auto $TRANSCRIPT' \\
    >> '$(dirname "$LOG_FILE")/headless.log' 2>&1
  RC=\$?
  TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ \$RC -ne 0 ]; then
    echo \"\$TS ERROR source=claude-p code=\$RC transcript=$TRANSCRIPT\" >> '$LOG_FILE'
  else
    echo \"\$TS COMPLETED source=claude-p transcript=$TRANSCRIPT\" >> '$LOG_FILE'
  fi
" >/dev/null 2>&1 &
disown

log "SPAWNED pid=$! model=$MODEL scripts=$SCRIPTS_DIR transcript=$TRANSCRIPT"
```

Note on quoting: `$RC` and `$TS` are escaped (`\$RC`, `\$TS`) so they expand inside the wrapper at runtime. `$TRANSCRIPT`, `$MODEL`, `$LOG_FILE` expand at trigger.sh time so the wrapper has them baked in.

- [ ] **Step 3: Add wrapper test — claude-p exit code captured**

Append to `tests/test_trigger.sh` after Case 8:

```bash
# === Case 9: claude-p exit code captured by wrapper ===
# Override claude with a stub that exits with code 7. Wrapper should log ERROR.
reset_log
STUB_DIR=$(mktemp -d "/tmp/dream-claude-stub-XXXXXX")
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$STUB_DIR/claude"

unset DREAM_DISPATCH_STUB
PATH="$STUB_DIR:$PATH" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"

# Wait briefly for background wrapper (stub exits immediately)
for i in 1 2 3 4 5; do
  grep -q "ERROR source=claude-p code=7" "$DREAM_LOG" 2>/dev/null && break
  sleep 0.5
done

grep -q "ERROR source=claude-p code=7" "$DREAM_LOG" || fail "wrapper did not log ERROR for claude-p exit 7"
echo "PASS: wrapper captures claude-p non-zero exit + logs ERROR"

# Restore stub for any subsequent cases
export DREAM_DISPATCH_STUB=1
```

- [ ] **Step 4: Run all tests, expect PASS**

```bash
cd dream-skill && for t in tests/test_*.sh; do echo "=== $t ==="; bash "$t" 2>&1 | tail -3; done
```

Expected: every existing suite still passes + new Case 9 PASS in test_trigger.sh.

- [ ] **Step 5: Commit**

```bash
git add dream-skill/scripts/trigger.sh dream-skill/tests/test_trigger.sh
git commit -m "feat(dream-skill): trigger.sh wraps claude -p spawn, logs ERROR on failure

Background wrapper captures \$? from claude -p:
- exit 0  → log COMPLETED source=claude-p transcript=...
- exit !0 → log ERROR source=claude-p code=N

Pre-flight ERROR lines now use structured source=trigger code=N msg=...
format for grep-ability. SKIP paths unchanged. Outer nohup preserves
fire-and-forget — trigger.sh returns immediately."
```

---

### Task 2: SKILL.md auto-mode appends COMPLETED/ERROR to trigger.log

**Files:**
- Modify: `dream-skill/skills/dream-skill/SKILL.md`
- Modify: `dream-skill/scripts/trigger.sh` (export `DREAM_LOG`)

**Behavior contract:** Add Step 6 instructing the headless LLM to append exactly one line to `$DREAM_LOG` before exiting. No notifications. Just a log line.

- [ ] **Step 1: Export `DREAM_LOG` from trigger.sh**

In trigger.sh env-export block (around line 128-136), add:

```bash
export DREAM_LOG  # explicit export so the headless skill can append completion markers
```

- [ ] **Step 2: Add `DREAM_LOG` to the SKILL.md env-var table**

Find the env-var table (around lines 92-102). Append:

```markdown
| `DREAM_LOG` | `$DREAM_HOME/trigger.log` | Append-only dispatch decisions + completion markers |
```

- [ ] **Step 3: Add Step 6 "Record completion" to SKILL.md auto-mode**

Append after the current last numbered step. Insert verbatim:

```markdown
### Step 6 — Record completion to $DREAM_LOG

ALWAYS run this as the FINAL action of auto mode, regardless of which exit branch you took. Without it, `check-pending.sh` will see your `SPAWNED` line as an orphan on the next session start and append a false-alarm `WARNING` line to the log.

Append exactly ONE line to `$DREAM_LOG` (NOT to `$DREAM_DAILY_LOG` — that's a different file for human-readable summaries).

**On successful or legitimate-skip completion** (Step 4 normal completion / Step 1 empty / Step 3 recursive / Step 3 no-info):

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS COMPLETED source=skill reason=<reason> writes=<N> queued=<N> dropped=<N> transcript=$DREAM_TRANSCRIPT" >> "$DREAM_LOG"
```

Reason enum (use one):
- `wrote-N` — Step 4 normal completion (N is total `[WRITE]` count)
- `empty-transcript` — Step 1 stripped output was <5 lines
- `recursive-transcript` — Step 3 every line was a dream-skill discussion
- `no-info-gain` — Step 3 candidates extracted but all dropped (Bucket B/C)

**On internal ERROR** (Step 0 env validation failed, vault-writer.sh non-zero, any unhandled error):

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS ERROR source=skill code=1 msg=\"<short msg>\" transcript=$DREAM_TRANSCRIPT" >> "$DREAM_LOG"
```

This is the contract that lets the user see silent failures. If you skip Step 6, the next-session orphan scanner will produce a spurious `WARNING` line. **Always close the loop.**
```

- [ ] **Step 4: Add Rule 4 to HARD RULES section**

Find the HARD RULES section. Append:

```markdown
### Rule 4 — Always close the trigger.log loop

Every auto-mode invocation MUST end with a `COMPLETED` or `ERROR` line appended to `$DREAM_LOG` (see Step 6). trigger.sh logged a `SPAWNED` line right before invoking you; check-pending.sh treats unmatched `SPAWNED` lines as silent failures and writes a `WARNING kind=orphan` to the log. If you skip Step 6, the log gets spurious orphan warnings.
```

- [ ] **Step 5: Commit (no separate test — this is prompt content the headless LLM must follow; behavior verified end-to-end in Task 6 manual smoke)**

```bash
git add dream-skill/scripts/trigger.sh dream-skill/skills/dream-skill/SKILL.md
git commit -m "feat(dream-skill): SKILL.md appends COMPLETED/ERROR to trigger.log

Step 6 instructs the headless LLM to close the trigger.log loop at every
exit branch (Step 0 env-fail / Step 1 empty / Step 3 recursive /
Step 3 no-info / Step 4 normal / vault-writer error). trigger.sh now
exports DREAM_LOG so the skill can write to the same file the wrapper
uses. Rule 4 added to HARD RULES so this contract isn't dropped.
check-pending.sh (next task) relies on these markers to detect silent
aborts."
```

---

### Task 3: check-pending.sh orphan scanner

**Files:**
- Create: `dream-skill/scripts/check-pending.sh`
- Create: `dream-skill/tests/test_check_pending.sh`
- Create: `dream-skill/tests/fixtures/trigger-log-orphan.txt`
- Create: `dream-skill/tests/fixtures/trigger-log-completed.txt`
- Create: `dream-skill/tests/fixtures/trigger-log-errored.txt`
- Create: `dream-skill/tests/fixtures/trigger-log-already-warned.txt`

**Behavior contract:**
- Reads `${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}`
- For each `SPAWNED` line in the last 1h (configurable via `DREAM_ORPHAN_WINDOW_SEC`):
  - Skip if timestamp younger than 5 min grace (`DREAM_ORPHAN_GRACE_SEC`)
  - Skip if a LATER line matches: `COMPLETED transcript=<same>`, `ERROR transcript=<same>`, OR `WARNING ... transcript=<same>`
  - Otherwise: append `WARNING kind=orphan transcript=<path> spawned-at=<ts>` to the log
- Always exits 0, never writes to stdout, never blocks SessionStart

- [ ] **Step 1: Create fixture log files**

`tests/fixtures/trigger-log-orphan.txt`:
```
2026-05-27T16:30:00Z DISPATCH count=15 threshold=5 transcript=/tmp/conv-A.jsonl
2026-05-27T16:30:00Z SPAWNED pid=1001 model=claude-haiku-4-5 transcript=/tmp/conv-A.jsonl
```

`tests/fixtures/trigger-log-completed.txt`:
```
2026-05-27T16:30:00Z DISPATCH count=15 threshold=5 transcript=/tmp/conv-B.jsonl
2026-05-27T16:30:00Z SPAWNED pid=1002 model=claude-haiku-4-5 transcript=/tmp/conv-B.jsonl
2026-05-27T16:31:30Z COMPLETED source=skill reason=wrote-2 writes=2 queued=0 dropped=1 transcript=/tmp/conv-B.jsonl
```

`tests/fixtures/trigger-log-errored.txt`:
```
2026-05-27T16:30:00Z DISPATCH count=15 threshold=5 transcript=/tmp/conv-C.jsonl
2026-05-27T16:30:00Z SPAWNED pid=1003 model=claude-haiku-4-5 transcript=/tmp/conv-C.jsonl
2026-05-27T16:30:15Z ERROR source=claude-p code=2 transcript=/tmp/conv-C.jsonl
```

`tests/fixtures/trigger-log-already-warned.txt`:
```
2026-05-27T16:30:00Z DISPATCH count=15 threshold=5 transcript=/tmp/conv-D.jsonl
2026-05-27T16:30:00Z SPAWNED pid=1004 model=claude-haiku-4-5 transcript=/tmp/conv-D.jsonl
2026-05-27T17:00:00Z WARNING kind=orphan transcript=/tmp/conv-D.jsonl spawned-at=2026-05-27T16:30:00Z
```

- [ ] **Step 2: Write failing test**

`tests/test_check_pending.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/check-pending.sh"
FIX="$SCRIPT_DIR/fixtures"

[ -x "$CHECK" ] || { echo "FAIL: check-pending.sh missing or not executable"; exit 1; }

TMP=$(mktemp -d "/tmp/dream-check-pending-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; cat "$DREAM_LOG" 2>/dev/null; exit 1; }

# Helper: count WARNING orphan lines in current log
count_warnings() {
  grep -c "WARNING kind=orphan" "$DREAM_LOG" 2>/dev/null || echo 0
}

# === T1: orphan older than grace → appends WARNING line ===
cp "$FIX/trigger-log-orphan.txt" "$TMP/orphan.log"
export DREAM_LOG="$TMP/orphan.log"
export DREAM_ORPHAN_GRACE_SEC=0   # disable grace for this test
"$CHECK"
WARN_COUNT=$(count_warnings)
[ "$WARN_COUNT" -eq 1 ] || fail "expected 1 WARNING line for orphan, got $WARN_COUNT"
grep -q "WARNING kind=orphan.*conv-A.jsonl" "$DREAM_LOG" || fail "WARNING line missing or wrong transcript"
echo "PASS: orphan → appends WARNING line"

# === T2: completed spawn → no WARNING ===
cp "$FIX/trigger-log-completed.txt" "$TMP/completed.log"
export DREAM_LOG="$TMP/completed.log"
"$CHECK"
WARN_COUNT=$(count_warnings)
[ "$WARN_COUNT" -eq 0 ] || fail "completed spawn wrongly produced WARNING (count=$WARN_COUNT)"
echo "PASS: completed spawn → silent"

# === T3: errored spawn → no orphan WARNING (ERROR already in log) ===
cp "$FIX/trigger-log-errored.txt" "$TMP/errored.log"
export DREAM_LOG="$TMP/errored.log"
"$CHECK"
WARN_COUNT=$(count_warnings)
[ "$WARN_COUNT" -eq 0 ] || fail "errored spawn wrongly produced WARNING orphan (count=$WARN_COUNT)"
echo "PASS: errored spawn → silent (ERROR already recorded)"

# === T4: already-warned spawn → no duplicate WARNING ===
cp "$FIX/trigger-log-already-warned.txt" "$TMP/warned.log"
export DREAM_LOG="$TMP/warned.log"
INITIAL_COUNT=$(count_warnings)
[ "$INITIAL_COUNT" -eq 1 ] || fail "fixture should start with 1 WARNING (got $INITIAL_COUNT)"
"$CHECK"
FINAL_COUNT=$(count_warnings)
[ "$FINAL_COUNT" -eq 1 ] || fail "already-warned orphan wrongly re-warned (final count=$FINAL_COUNT)"
echo "PASS: already-warned orphan → no duplicate"

# === T5: missing log file → silent, exit 0 ===
export DREAM_LOG="$TMP/nonexistent.log"
"$CHECK" || fail "non-zero exit on missing log"
echo "PASS: missing log → silent + exit 0"

# === T6: malformed line → exit 0, no crash ===
echo "garbage non-parseable line" > "$TMP/malformed.log"
export DREAM_LOG="$TMP/malformed.log"
"$CHECK" || fail "non-zero exit on malformed log"
echo "PASS: malformed log → exit 0"

# === T7: spawn within grace window → no WARNING ===
cp "$FIX/trigger-log-orphan.txt" "$TMP/fresh.log"
export DREAM_LOG="$TMP/fresh.log"
export DREAM_ORPHAN_GRACE_SEC=86400   # 24h grace — way more than any test ts
"$CHECK"
WARN_COUNT=$(count_warnings)
[ "$WARN_COUNT" -eq 0 ] || fail "spawn within grace window wrongly produced WARNING (count=$WARN_COUNT)"
echo "PASS: spawn within grace window → silent"

# === T8: idempotent — running check twice produces only 1 WARNING per orphan ===
cp "$FIX/trigger-log-orphan.txt" "$TMP/dual.log"
export DREAM_LOG="$TMP/dual.log"
export DREAM_ORPHAN_GRACE_SEC=0
"$CHECK"
"$CHECK"
WARN_COUNT=$(count_warnings)
[ "$WARN_COUNT" -eq 1 ] || fail "duplicate run produced multiple WARNINGs (count=$WARN_COUNT)"
echo "PASS: duplicate runs are idempotent (only 1 WARNING per orphan)"

echo
echo "All check-pending tests passed."
```

- [ ] **Step 3: Run test, expect FAIL (script doesn't exist)**

```bash
chmod +x dream-skill/tests/test_check_pending.sh
dream-skill/tests/test_check_pending.sh
```

Expected: `FAIL: check-pending.sh missing or not executable`

- [ ] **Step 4: Implement check-pending.sh**

```bash
#!/usr/bin/env bash
# dream-skill orphan scanner. Runs as SessionStart hook.
# Reads trigger.log; for each SPAWNED line outside the grace window,
# checks for a matching COMPLETED / ERROR / WARNING. Orphans → append
# WARNING line. Idempotent — once a WARNING exists for a transcript,
# we never duplicate it. Outputs nothing to stdout (zero context cost).
# Always exits 0.

set -uo pipefail   # NOT -e — never break SessionStart

LOG="${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}"
GRACE_SEC="${DREAM_ORPHAN_GRACE_SEC:-300}"     # 5 min default
WINDOW_SEC="${DREAM_ORPHAN_WINDOW_SEC:-3600}"  # 1h lookback

[ -f "$LOG" ] || exit 0
command -v awk >/dev/null 2>&1 || exit 0

NOW=$(date +%s)
WINDOW_CUTOFF=$((NOW - WINDOW_SEC))
GRACE_CUTOFF=$((NOW - GRACE_SEC))

# Parse epoch from ISO-8601 timestamp (BSD + GNU date)
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
  ts=$1
  for (i=2; i<=NF; i++) if ($i ~ /^transcript=/) { sub(/^transcript=/, "", $i); print ts" "$i }
}' "$LOG" > "$SPAWNS" 2>/dev/null || true

# COMPLETED or ERROR lines — both represent "spawn resolved"
awk '/COMPLETED|^[^ ]+ ERROR/ {
  for (i=2; i<=NF; i++) if ($i ~ /^transcript=/) { sub(/^transcript=/, "", $i); print $i }
}' "$LOG" > "$COMPLETIONS" 2>/dev/null || true

# Existing WARNING orphan lines — for dedupe
awk '/WARNING kind=orphan/ {
  for (i=2; i<=NF; i++) if ($i ~ /^transcript=/) { sub(/^transcript=/, "", $i); print $i }
}' "$LOG" > "$WARNED" 2>/dev/null || true

# For each SPAWNED: decide orphan vs not
while IFS=' ' read -r SP_TS SP_PATH; do
  [ -n "${SP_PATH:-}" ] || continue

  SP_EPOCH=$(to_epoch "$SP_TS")
  [ "$SP_EPOCH" -gt 0 ] || continue
  [ "$SP_EPOCH" -gt "$WINDOW_CUTOFF" ] || continue   # outside lookback
  [ "$SP_EPOCH" -lt "$GRACE_CUTOFF" ] || continue    # within grace, skip

  # Already resolved?
  grep -Fxq "$SP_PATH" "$COMPLETIONS" 2>/dev/null && continue
  # Already warned?
  grep -Fxq "$SP_PATH" "$WARNED" 2>/dev/null && continue

  # Orphan: append WARNING line to the log
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$TS WARNING kind=orphan transcript=$SP_PATH spawned-at=$SP_TS" >> "$LOG"
done < "$SPAWNS"

exit 0
```

- [ ] **Step 5: Run tests, expect PASS**

```bash
chmod +x dream-skill/scripts/check-pending.sh
dream-skill/tests/test_check_pending.sh
```

Expected: T1–T8 all PASS.

- [ ] **Step 6: Commit**

```bash
git add dream-skill/scripts/check-pending.sh dream-skill/tests/test_check_pending.sh dream-skill/tests/fixtures/trigger-log-*.txt
git commit -m "feat(dream-skill): check-pending.sh — orphan SPAWNED detector

SessionStart hook. Scans trigger.log for SPAWNED lines older than
5 min (grace) without matching COMPLETED/ERROR/WARNING. For each
orphan: appends WARNING kind=orphan line so the user sees silent
aborts on next \`tail trigger.log\`. Idempotent — never duplicates
WARNINGs. Zero stdout output, always exits 0. Tests cover:
orphan/completed/errored/already-warned/missing-log/malformed-log/
grace-window/double-run-idempotency."
```

---

### Task 4: Register SessionStart hook

**Files:**
- Modify: `dream-skill/hooks/hooks.json`
- Modify: `~/.claude/settings.json` (local dev only — production users get it via plugin install)

- [ ] **Step 1: Add SessionStart block to hooks/hooks.json**

Current file has only SessionEnd. Add SessionStart sibling:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/check-pending.sh",
            "timeout": 3
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/trigger.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate JSON parses**

```bash
jq . dream-skill/hooks/hooks.json
```

Expected: re-prints both blocks without error.

- [ ] **Step 3: Wire into local settings.json (dev-only)**

```bash
jq '.hooks.SessionStart = (
  (.hooks.SessionStart // []) + [{
    "hooks": [{
      "type": "command",
      "command": "/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/scripts/check-pending.sh",
      "timeout": 3
    }]
  }]
)' /Users/bohdan/.claude/settings.json > /Users/bohdan/.claude/settings.json.new \
&& mv /Users/bohdan/.claude/settings.json.new /Users/bohdan/.claude/settings.json
jq '.hooks.SessionStart[-1]' /Users/bohdan/.claude/settings.json
```

Expected: the new check-pending.sh entry visible at the end of the SessionStart array.

- [ ] **Step 4: Commit**

```bash
git add dream-skill/hooks/hooks.json
git commit -m "feat(dream-skill): register SessionStart hook for orphan scanner

Adds SessionStart entry pointing at scripts/check-pending.sh. Auto-
installs on /plugin install alongside the existing SessionEnd hook.
Local settings.json wired manually for dev."
```

---

### Task 5: README updates

**Files:**
- Modify: `dream-skill/README.md`

- [ ] **Step 1: Insert FAQ entry**

In the FAQ section (between Privacy and Roadmap), add:

```markdown
**Q: How do I know if dream-skill failed silently?**
Everything goes to `~/.claude/dream-skill/trigger.log`. Three failure modes get distinct lines:

| Line | Meaning |
|---|---|
| `ERROR source=trigger ...` | trigger.sh pre-flight failure (claude CLI missing, etc.) |
| `ERROR source=claude-p code=N ...` | `claude -p` exited non-zero (API error, timeout, crash) |
| `WARNING kind=orphan ...` | A spawn never completed — silent abort inside the headless skill |

To check periodically:

```bash
tail ~/.claude/dream-skill/trigger.log              # last 10 events
grep -E "ERROR|WARNING" ~/.claude/dream-skill/trigger.log   # all failures
```

Legitimate skips (below threshold, duplicate dispatch, empty transcript) appear as `SKIP` lines — not failures. No popups, no Claude-context injection — pure log output.
```

- [ ] **Step 2: Update Safety section**

Find `## Safety`, append:

```markdown
- **Failure logging** — every outcome (success, skip, error, silent abort) lands in `~/.claude/dream-skill/trigger.log`. Grep for `ERROR` or `WARNING` to see failures. Zero notifications, zero context pollution.
```

- [ ] **Step 3: Update State layout block**

Find the state-layout fenced code block. Update the trigger.log line:

```
~/.claude/dream-skill/
├── config.toml              # vault roots (you create this)
├── trigger.log              # ALL dispatch outcomes: SKIP / DISPATCH / SPAWNED / COMPLETED / ERROR / WARNING
├── headless.log             # stdout/stderr from spawned claude -p
├── error.log                # broken-install diagnostics
├── log/<date>.md            # per-day human-readable activity log (written by SKILL.md)
├── undo/<date>.jsonl        # per-write rollback entries
└── queue/pending.md         # deferred-decision facts
```

- [ ] **Step 4: Commit**

```bash
git add dream-skill/README.md
git commit -m "docs(dream-skill): document failure logging — trigger.log as single source"
```

---

### Task 6: End-to-end manual smoke test

**Files:** none (manual verification)

- [ ] **Step 1: Force a trigger.sh pre-flight ERROR**

Remove claude from PATH so the cli-missing branch fires:

```bash
PATH=/usr/bin:/bin CLAUDE_TRANSCRIPT_PATH="/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/tests/fixtures/transcript-15msg.jsonl" \
  /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/scripts/trigger.sh
```

Verify the log:

```bash
tail -2 ~/.claude/dream-skill/trigger.log
```

Expected: a new line like `... ERROR source=trigger code=127 msg=claude-cli-missing`.

- [ ] **Step 2: Force an orphan-detection cycle**

Manually inject an old SPAWNED line with no completion, then run check-pending.sh:

```bash
OLD_TS=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
echo "$OLD_TS SPAWNED pid=99999 model=test transcript=/tmp/fake-orphan-test.jsonl" >> ~/.claude/dream-skill/trigger.log

/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/scripts/check-pending.sh

tail -3 ~/.claude/dream-skill/trigger.log
```

Expected: a new `WARNING kind=orphan transcript=/tmp/fake-orphan-test.jsonl spawned-at=...` line at the end.

- [ ] **Step 3: Re-run check-pending.sh, verify dedupe**

```bash
WARN_COUNT_BEFORE=$(grep -c "fake-orphan-test" ~/.claude/dream-skill/trigger.log)
/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill/scripts/check-pending.sh
WARN_COUNT_AFTER=$(grep -c "fake-orphan-test" ~/.claude/dream-skill/trigger.log)
echo "before=$WARN_COUNT_BEFORE after=$WARN_COUNT_AFTER"
```

Expected: counts equal — the WARNING line is NOT duplicated. (You'll see the SPAWNED line + 1 WARNING line = 2 references total in both counts.)

- [ ] **Step 4: Clean up synthetic entries**

```bash
sed -i.bak '/fake-orphan-test/d' ~/.claude/dream-skill/trigger.log
rm ~/.claude/dream-skill/trigger.log.bak
```

- [ ] **Step 5: Close + reopen Claude Code, verify SessionStart hook ran without noise**

After reopen:

```bash
tail ~/.claude/dream-skill/trigger.log
```

Expected: no new spurious WARNING lines for real transcripts. SessionStart hook ran silently.

---

### Task 7: Run full suite + push to origin

- [ ] **Step 1: Verify tree clean + all tests pass**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills
git status
cd dream-skill && for t in tests/test_*.sh; do echo "=== $t ==="; bash "$t" 2>&1 | tail -2; done
```

Expected: working tree clean (or only PLAN-warning-system.md if untracked), all 7 suites PASS.

- [ ] **Step 2: Push**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills
git push origin main
```

Expected: 5 new commits land on origin/main (T1-T5; T6 manual, T7 housekeeping).

---

## Self-review checklist

- [x] **Spec coverage:**
  - trigger.log as source of truth → Tasks 1, 2, 3 (read/write contract)
  - trigger.sh pre-flight ERROR → Task 1 (Step 1)
  - `claude -p` non-zero exit caught by wrapper → Task 1 (Step 2)
  - SKILL.md internal ERROR + COMPLETED markers → Task 2
  - Orphan detection (silent abort) → Task 3
  - Idempotent WARNING (no log spam) → Task 3 (Test T4 + T8)
  - SessionStart hook registration → Task 4
  - README docs → Task 5
  - End-to-end verification → Task 6

- [x] **No placeholders:** every step has concrete bash, exact JSON, exact line formats.

- [x] **No notifications anywhere:** zero `osascript` / `notify-send` calls. Only `echo ... >> $LOG`.

- [x] **Type consistency:**
  - Line prefixes `SKIP / DISPATCH / SPAWNED / COMPLETED / ERROR / WARNING` used identically in trigger.sh wrapper, SKILL.md, check-pending.sh, tests
  - `transcript=<path>` key consistent (no `transcript_path=` variants)
  - `source=<trigger|claude-p|skill>` enum consistent in ERROR lines
  - `$DREAM_LOG` env var used in trigger.sh + SKILL.md + check-pending.sh + tests
  - 5-min grace window referenced in check-pending.sh constant + SKILL.md Step 6 + test setup

- [x] **Zero context pollution:** SessionStart hook outputs NOTHING to stdout — only appends to log.

- [x] **Cross-platform safety:** epoch-parse helper handles BSD + GNU `date`.

- [x] **Fire-and-forget preserved:** trigger.sh returns immediately, SessionStart timeout 3s.

## Open considerations (not blocking)

- **trigger.log rotation:** file grows unbounded. Trivial at current cadence (~10 lines/session). Add rotation in v0.3 if needed.
- **WARNING accumulation:** every orphan adds one line forever. ~80 bytes per orphan. Same v0.3 concern.

---

## Execution handoff

Plan complete and saved to `dream-skill/PLAN-warning-system.md`. Two options:

1. **Inline (recommended)** — I run 7 tasks here sequentially, checkpoint after Task 3 (orphan scanner green) and Task 6 (manual smoke). 5 commits.

2. **Subagent-driven** — fresh dispatch per task, slower.

Start Task 1?
