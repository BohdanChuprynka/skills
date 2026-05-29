# Dream-report Vault Progress Log — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every headless dream-skill run leave a human-readable, Obsidian-visible entry in `dream-reports/dream-<date>.md` so the user can confirm at a glance that it ran and what it captured.

**Architecture:** A new best-effort `scripts/report.sh` owns the report format. `trigger.sh` calls it for layer-1 skips (below-threshold, no-transcript); the auto-mode skill calls it once at its final action for spawned-run outcomes (wrote / noop / error). The hidden `~/.claude/dream-skill/` logs are untouched.

**Tech Stack:** Bash (POSIX-ish, macOS `bash 3.2`-safe), the existing dream-skill script + test conventions.

**Concurrency note:** A second Claude Code session is actively editing `scripts/trigger.sh` and `skills/dream-skill/SKILL.md`. `report.sh` and `test_report.sh` are new files (no collision). For the two modified files, re-read immediately before editing and use surgical `Edit` (never full-file `Write`), so a stale region fails the edit instead of clobbering their work.

---

## File Structure

- **Create `scripts/report.sh`** — the single report-format owner. Resolves the reports dir, creates the day file with frontmatter, appends one entry. Best-effort (always exit 0).
- **Create `tests/test_report.sh`** — unit tests for `report.sh`.
- **Modify `scripts/trigger.sh`** — parse `cwd`, compute+export `DREAM_CHAT_LABEL`, resolve `REPORT_SH` path, call `report.sh` at the below-threshold and unresolved-file-not-found skip branches.
- **Modify `tests/test_trigger.sh`** — assert those skips now produce a vault entry, and that a successful dispatch does not.
- **Modify `skills/dream-skill/SKILL.md`** — add one `report.sh` call to Step 6 (final action), on every exit branch.
- **Modify `~/.claude/dream-skill/config.toml`** (live config, not in repo) — add explicit `reports_dir` key.

---

## Task 1: `report.sh` + its tests

**Files:**
- Create: `scripts/report.sh`
- Create: `tests/test_report.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_report.sh`

```bash
#!/usr/bin/env bash
# Test: report.sh — vault progress entries, best-effort, burst-safe
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="$SCRIPT_DIR/../scripts/report.sh"
[ -x "$REPORT" ] || { echo "FAIL: report.sh missing or not executable at $REPORT"; exit 1; }

RD="$(mktemp -d /tmp/dream-reports-test-XXXXXX)"
export DREAM_ERROR_LOG="$RD/error.log"
trap 'rm -rf "$RD"' EXIT
fail() { echo "FAIL: $*"; echo "--- file ---"; cat "$RD"/dream-*.md 2>/dev/null; exit 1; }
DATE="$(date +%Y-%m-%d)"
FILE="$RD/dream-$DATE.md"

# Case 1: first write creates file with frontmatter + H1
"$REPORT" --status skipped --chat "abc12345 (Obsidian)" --reason "below-threshold (0 user messages)" --reports-dir "$RD"
grep -q "^type: dream-activity-log$" "$FILE" || fail "no frontmatter type"
grep -q "^# Dream activity — $DATE$" "$FILE" || fail "no H1 header"
grep -q "^### .* — skipped$" "$FILE" || fail "no skipped header"
grep -q "^reason: below-threshold (0 user messages)$" "$FILE" || fail "no reason line"
echo "PASS: first write creates file + skipped entry"

# Case 2: wrote — header count == [WRITE] lines on stdin, contents block present
printf -- '- [WRITE] me/wiki/x.md: a\n- [WRITE] me/wiki/y.md: b\n- [DROP] noise\n' \
  | "$REPORT" --status wrote --chat "def67890 (Obsidian)" --reports-dir "$RD"
grep -q "^### .* — wrote 2$" "$FILE" || fail "wrote header count wrong"
grep -q "^contents:$" "$FILE" || fail "no contents block"
grep -q "^- \[DROP\] noise$" "$FILE" || fail "drop line not preserved"
echo "PASS: wrote entry counts [WRITE] lines and keeps body"

# Case 3: noop
"$REPORT" --status noop --chat "self-ref" --reason "recursive-meta (no persona signal)" --reports-dir "$RD"
grep -q "^### .* — ran, 0 writes$" "$FILE" || fail "no noop header"
echo "PASS: noop entry"

# Case 4: error
"$REPORT" --status error --chat "b419 (Obsidian)" --reason "see error.log" --reports-dir "$RD"
grep -q "^### .* — error$" "$FILE" || fail "no error header"
echo "PASS: error entry"

# Case 5: best-effort — unwritable reports dir → exit 0, no crash
BLOCK="$RD/blockfile"; : > "$BLOCK"   # a regular file; can't be a dir
set +e
"$REPORT" --status skipped --chat "x" --reason "y" --reports-dir "$BLOCK/sub"; rc=$?
set -e 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "unwritable dir did not exit 0 (rc=$rc)"
echo "PASS: unwritable reports dir exits 0"

# Case 6: missing --status → exit 0 (best-effort)
"$REPORT" --chat "x" --reports-dir "$RD"; [ $? -eq 0 ] || fail "missing --status did not exit 0"
echo "PASS: missing --status exits 0"

# Case 7: concurrent appends — both land intact (atomic O_APPEND)
RD2="$(mktemp -d /tmp/dream-reports-conc-XXXXXX)"
F2="$RD2/dream-$DATE.md"
"$REPORT" --status noop --chat "aaa" --reason "first"  --reports-dir "$RD2" &
"$REPORT" --status noop --chat "bbb" --reason "second" --reports-dir "$RD2" &
wait
grep -q "^chat: aaa$" "$F2" || fail "concurrent: first entry missing"
grep -q "^chat: bbb$" "$F2" || fail "concurrent: second entry missing"
[ "$(grep -c '^### ' "$F2")" -eq 2 ] || fail "concurrent: expected 2 entries"
rm -rf "$RD2"
echo "PASS: concurrent appends both land"

echo
echo "All report.sh tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_report.sh`
Expected: FAIL fast — `report.sh missing or not executable`.

- [ ] **Step 3: Write minimal implementation** — `scripts/report.sh`

```bash
#!/usr/bin/env bash
# dream-skill vault progress reporter.
# Appends ONE human-readable entry per run to the day's report file in the
# vault's dream-reports/ folder, so dream-skill activity is visible in Obsidian.
# Best-effort: ALWAYS exits 0; never breaks the caller (trigger.sh is
# fire-and-forget; the auto skill must not crash on a report failure).
#
# Usage:
#   report.sh --status <wrote|noop|skipped|error> --chat "<label>" \
#             [--reason "<text>"] [--time "<HH:MM TZ>"] [--reports-dir <dir>]
#   # When --status wrote, the [WRITE]/[QUEUE]/[DROP] body lines are read from stdin.
#
# Reports dir resolution: --reports-dir → $DREAM_REPORTS_DIR → config reports_dir
#   → <Obsidian root>/dream-reports (parent of the first configured vault root).

set -uo pipefail   # deliberately NOT -e: best-effort, must always reach exit 0

STATUS=""; CHAT=""; REASON=""; TIME_STR=""; REPORTS_DIR_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --status)      STATUS="${2:-}"; shift 2 ;;
    --chat)        CHAT="${2:-}"; shift 2 ;;
    --reason)      REASON="${2:-}"; shift 2 ;;
    --time)        TIME_STR="${2:-}"; shift 2 ;;
    --reports-dir) REPORTS_DIR_ARG="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

ERROR_LOG="${DREAM_ERROR_LOG:-$HOME/.claude/dream-skill/error.log}"
note_err() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) report.sh: $*" >> "$ERROR_LOG" 2>/dev/null || true; }

resolve_reports_dir() {
  if [ -n "$REPORTS_DIR_ARG" ]; then printf '%s' "$REPORTS_DIR_ARG"; return; fi
  if [ -n "${DREAM_REPORTS_DIR:-}" ]; then printf '%s' "$DREAM_REPORTS_DIR"; return; fi
  local cfg="${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}"
  local explicit first_root
  explicit=$(grep -E '^[[:space:]]*reports_dir[[:space:]]*=' "$cfg" 2>/dev/null | head -1 \
             | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return; fi
  first_root=$(grep -E '^[[:space:]]*root[[:space:]]*=' "$cfg" 2>/dev/null | head -1 \
               | sed -E 's/.*"([^"]*)".*/\1/')
  if [ -n "$first_root" ]; then printf '%s/dream-reports' "$(dirname "$first_root")"; return; fi
  printf ''
}

[ -n "$STATUS" ] || { note_err "missing --status"; exit 0; }

REPORTS_DIR="$(resolve_reports_dir)"
[ -n "$REPORTS_DIR" ] || { note_err "could not resolve reports dir"; exit 0; }
mkdir -p "$REPORTS_DIR" 2>/dev/null || { note_err "cannot create $REPORTS_DIR"; exit 0; }

DATE="$(date +%Y-%m-%d)"                       # local date for the filename
TIME_STR="${TIME_STR:-$(date +'%H:%M %Z')}"    # local time for the entry
FILE="$REPORTS_DIR/dream-$DATE.md"

# Create the day file with frontmatter + H1 exactly once (noclobber = race-safe).
( set -o noclobber
  printf -- '---\ntype: dream-activity-log\ndate: %s\n---\n\n# Dream activity — %s\n' "$DATE" "$DATE" > "$FILE"
) 2>/dev/null || true
[ -f "$FILE" ] || { note_err "cannot write $FILE"; exit 0; }

# Optional body (stdin), meaningful only for --status wrote.
BODY=""
[ -t 0 ] || BODY="$(cat 2>/dev/null || true)"

case "$STATUS" in
  wrote)
    n=$(printf '%s\n' "$BODY" | grep -cE '^[[:space:]]*-[[:space:]]*\[WRITE\]' 2>/dev/null) || n=0
    head_status="wrote $n" ;;
  noop)    head_status="ran, 0 writes" ;;
  skipped) head_status="skipped" ;;
  error)   head_status="error" ;;
  *)       head_status="$STATUS" ;;
esac

ENTRY="$(printf '\n### %s — %s\nchat: %s\n' "$TIME_STR" "$head_status" "${CHAT:-unknown}")"
if [ "$STATUS" = "wrote" ] && [ -n "$BODY" ]; then
  ENTRY="$ENTRY$(printf 'contents:\n%s\n' "$BODY")"
elif [ -n "$REASON" ]; then
  ENTRY="$ENTRY$(printf 'reason: %s\n' "$REASON")"
fi

# Single O_APPEND write; entries are < PIPE_BUF (4 KB), so concurrent appends
# do not interleave on a local filesystem.
printf '%s\n' "$ENTRY" >> "$FILE" 2>/dev/null || note_err "append failed $FILE"
exit 0
```

Then `chmod +x scripts/report.sh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/report.sh && bash tests/test_report.sh`
Expected: PASS — all 7 cases, ending `All report.sh tests passed.`

- [ ] **Step 5: Commit** (new files only — safe under concurrency)

```bash
git add scripts/report.sh tests/test_report.sh
git commit -m "feat(dream-skill): report.sh — vault-visible per-run progress log"
```

---

## Task 2: Wire `report.sh` into `trigger.sh`

**Files:**
- Modify: `scripts/trigger.sh` (re-read first; anchors below are current as of this plan)
- Modify: `tests/test_trigger.sh`

- [ ] **Step 1: Write the failing tests** — append before the final `echo "All trigger.sh tests passed."` in `tests/test_trigger.sh`

```bash
# === Case 13: below-threshold skip writes a vault report entry ===
reset_log
RD13="$(mktemp -d /tmp/dream-trig-rep13-XXXXXX)"
DREAM_REPORTS_DIR="$RD13" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-0msg.jsonl" "$TRIGGER"
grep -q "^### .* — skipped$" "$RD13"/dream-*.md 2>/dev/null || fail "below-threshold skip wrote no vault entry"
grep -q "below-threshold" "$RD13"/dream-*.md 2>/dev/null || fail "vault entry missing below-threshold reason"
rm -rf "$RD13"
echo "PASS: below-threshold skip produces a vault report entry"

# === Case 14: successful dispatch writes NO vault entry (skill owns that) ===
reset_log
RD14="$(mktemp -d /tmp/dream-trig-rep14-XXXXXX)"
DREAM_REPORTS_DIR="$RD14" CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
[ -z "$(ls -A "$RD14" 2>/dev/null)" ] || fail "dispatch should not write a vault entry (skill does)"
rm -rf "$RD14"
echo "PASS: successful dispatch writes no vault entry"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_trigger.sh`
Expected: FAIL at Case 13 — `below-threshold skip wrote no vault entry`.

- [ ] **Step 3: Implement — edit `scripts/trigger.sh`**

3a. In the config block (after the `RESOLVE_WINDOW_SEC=` line), resolve the report helper path early:

```bash
# report.sh path (resolved early so skip branches can call it).
REPORT_SH="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}"
REPORT_SH="${REPORT_SH:-$(cd "$(dirname "$0")" && pwd)}/report.sh"

# chat label "<first8 of uuid> (<project>)" for report.sh entries.
dream_chat_label() {
  local tpath="$1" cwd="$2" id proj
  id="$(basename "${tpath%.jsonl}")"; id="${id:0:8}"
  if [ -n "$cwd" ]; then proj="$(basename "$cwd")"; else proj="$(basename "$(dirname "$tpath")")"; fi
  printf '%s (%s)' "${id:-unknown}" "${proj:-?}"
}
```

3b. In the stdin-JSON parse block, also capture `cwd` (add alongside the `REASON=` line):

```bash
    CWD=$(echo "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null || true)
```

Declare `CWD=""` next to `REASON=""` near the top of the resolve-transcript section.

3c. At the unresolved file-not-found branch (the `else` that logs `SKIP file-not-found`), add a report call before `exit 0`:

```bash
  else
    log "SKIP file-not-found path='$TRANSCRIPT'"
    "$REPORT_SH" --status skipped --chat "$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")" \
                 --reason "no transcript found" 2>/dev/null || true
    exit 0
  fi
```

3d. At the below-threshold branch, add a report call before `exit 0`:

```bash
if [ "$USER_MSGS" -lt "$THRESHOLD" ]; then
  log "SKIP below-threshold count=$USER_MSGS threshold=$THRESHOLD"
  "$REPORT_SH" --status skipped --chat "$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")" \
               --reason "below-threshold ($USER_MSGS user messages)" 2>/dev/null || true
  exit 0
fi
```

3e. In the export block (near the other `export DREAM_*` lines), export the label so the spawned skill reuses the same one:

```bash
export DREAM_CHAT_LABEL="$(dream_chat_label "$TRANSCRIPT" "${CWD:-}")"
```

Do **not** add report calls to the `no-path-provided`, `recursive-headless`, `reason=clear`, or `duplicate-dispatch` branches — those are non-events and stay in `trigger.log` only.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_trigger.sh`
Expected: PASS — all cases through Case 14, ending `All trigger.sh tests passed.`

- [ ] **Step 5: Commit** (re-read trigger.sh first; if the other session changed it, re-apply 3a–3e surgically)

```bash
git add scripts/trigger.sh tests/test_trigger.sh
git commit -m "feat(dream-skill): trigger.sh reports layer-1 skips to the vault log"
```

---

## Task 3: Wire `report.sh` into the auto-mode skill

**Files:**
- Modify: `skills/dream-skill/SKILL.md` (re-read first; Step 6 is the anchor)

- [ ] **Step 1: Add the report call to Step 6.** After the existing `COMPLETED`/`ERROR` `$DREAM_LOG` snippets in "Step 6 — Record completion", insert:

````markdown
**Also write the user-visible vault entry** (same final action; uses `$DREAM_CHAT_LABEL` exported by trigger.sh). Pick the matching branch:

```bash
LABEL="${DREAM_CHAT_LABEL:-$(basename "${DREAM_TRANSCRIPT%.jsonl}") (auto)}"

# wrote: pipe the SAME [WRITE]/[QUEUE]/[DROP] lines you appended to the daily log
printf '%s\n' "$DAILY_LOG_LINES" \
  | "$DREAM_SCRIPTS_DIR/report.sh" --status wrote --chat "$LABEL" 2>/dev/null || true

# noop (reason = empty-transcript | recursive-transcript | no-info-gain):
"$DREAM_SCRIPTS_DIR/report.sh" --status noop --chat "$LABEL" --reason "<that reason>" 2>/dev/null || true

# error:
"$DREAM_SCRIPTS_DIR/report.sh" --status error --chat "$LABEL" --reason "see error.log" 2>/dev/null || true
```

Run exactly ONE of these, matching the same outcome you recorded in the `$DREAM_LOG` line. It is best-effort: never let a report failure change your exit status.
````

- [ ] **Step 2: Verify (no unit test — prompt instructions).** Confirm the snippet uses only env vars guaranteed by `trigger.sh` (`DREAM_SCRIPTS_DIR`, `DREAM_TRANSCRIPT`, `DREAM_CHAT_LABEL`) and that the `wrote` branch reuses the Step 4 lines. Sanity-check `report.sh` directly with a representative call:

Run: `printf -- '- [WRITE] me/wiki/x.md: a\n' | DREAM_REPORTS_DIR=/tmp/skilltest scripts/report.sh --status wrote --chat "test (manual)"`
Expected: `/tmp/skilltest/dream-<date>.md` contains a `wrote 1` entry. Then `rm -rf /tmp/skilltest`.

- [ ] **Step 3: Commit** (re-read SKILL.md first)

```bash
git add skills/dream-skill/SKILL.md
git commit -m "feat(dream-skill): auto mode writes per-run entry to the vault log"
```

---

## Task 4: Config key + full-suite verification

**Files:**
- Modify: `~/.claude/dream-skill/config.toml` (live runtime config, not in repo)

- [ ] **Step 1: Add the explicit `reports_dir` key** near the top of `~/.claude/dream-skill/config.toml` (after the header comment):

```toml
# Where dream-skill writes its per-run progress log (a sibling folder of the
# vaults, visible in Obsidian; NOT a persona vault).
reports_dir = "/Users/bohdan/Documents/IT-Work/Projects/IT/Obsidian/dream-reports"
```

- [ ] **Step 2: Verify resolution end-to-end** without an explicit `--reports-dir` (exercises the config path):

Run: `DREAM_CONFIG="$HOME/.claude/dream-skill/config.toml" scripts/report.sh --status skipped --chat "verify (manual)" --reason "config-resolution check"`
Expected: a new entry appears in `/Users/bohdan/Documents/IT-Work/Projects/IT/Obsidian/dream-reports/dream-<date>.md`. Inspect, then delete that one verification entry by hand if you don't want it in the real log.

- [ ] **Step 3: Run the whole suite**

Run:
```bash
bash tests/test_report.sh && bash tests/test_trigger.sh && bash tests/test_check_pending.sh && bash tests/test_e2e.sh
```
Expected: every script ends with its `All ... passed.` line.

- [ ] **Step 4: Manual real-LLM smoke (optional, burns quota).** Close a small real session and confirm one entry lands in today's `dream-reports/dream-<date>.md` with the right status.

---

## Self-Review

**Spec coverage:** report.sh interface + 4 entry shapes (Task 1) ✓; one-entry-per-real-close via trigger.sh skips (Task 2) + skill outcomes (Task 3) ✓; exclusions kept out (Task 2 Step 3 note) ✓; config-driven reports_dir with derive fallback (Task 1 `resolve_reports_dir` + Task 4) ✓; best-effort + burst-safe (Task 1 impl + tests 5/7) ✓; tests (Tasks 1–2) ✓; `~/.claude` logs untouched ✓.

**Placeholder scan:** none — all code is literal; the only `<...>` is the skill's `--reason "<that reason>"`, which is an instruction to the LLM to substitute its actual reason enum, not a code placeholder.

**Type/name consistency:** `--status` values (`wrote|noop|skipped|error`), `DREAM_REPORTS_DIR`, `DREAM_CHAT_LABEL`, `dream_chat_label`, `REPORT_SH`, and `resolve_reports_dir` are used identically across tasks. Header strings (`wrote N`, `ran, 0 writes`, `skipped`, `error`) match between `report.sh` and the test assertions.
