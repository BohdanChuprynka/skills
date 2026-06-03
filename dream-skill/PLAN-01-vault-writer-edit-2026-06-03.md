# vault-writer edit/replace/mark-stale — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `vault-writer.sh` the ability to *replace* and *mark-stale* an existing fact line (not just append), and make every such edit reversible via `apply-undo.sh` — the foundational capability the reconciler needs to handle supersession/contradiction.

**Architecture:** Add a `--mode {append|replace|stale}` flag (default `append`, fully back-compatible) plus `--old-content` to `vault-writer.sh`. `replace` swaps an exact existing line for new content; `stale` annotates an existing line as superseded (strikethrough + dated marker). Both emit a uniform `action:"replace"` undo entry carrying `old_content` + `content`, which `apply-undo.sh` reverses by swapping the line back. All edits keep the existing per-page mkdir mutex and idempotency guarantees.

**Tech Stack:** Bash (POSIX-ish, `set -euo pipefail`), `awk` for exact-line edits, `jq` for undo JSONL, plain-shell tests (no bats) mirroring `tests/test_vault_writer.sh`.

**Repo root:** `/Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill`

---

## File Structure

- **Modify:** `scripts/vault-writer.sh` — add `--mode`/`--old-content` args, validation, and a `replace`/`stale` branch alongside the existing append branch.
- **Modify:** `scripts/apply-undo.sh` — add a `replace)` case that swaps `- <content>` back to `- <old_content>`.
- **Modify:** `tests/test_vault_writer.sh` — append Tests 8–12 for replace/stale/undo, in the existing style.

Append-mode behavior and all existing tests (1–7) must remain unchanged.

---

### Task 1: `replace` mode swaps an existing line

**Files:**
- Modify: `scripts/vault-writer.sh`
- Test: `tests/test_vault_writer.sh`

- [ ] **Step 1: Write the failing test** — append to the end of `tests/test_vault_writer.sh`, *before* the final `echo "All vault-writer.sh tests passed."` line:

```bash
# Test 8: replace mode swaps an existing line for new content
cat > "$VAULT/wiki/replace.md" <<'EOF'
# Replace

## Status
- lives in Berlin
EOF

"$WRITER" --vault "$VAULT" --page "wiki/replace.md" --section "Status" \
  --mode replace --old-content "lives in Berlin" \
  --content "lives in Munich (moved 2026-06)" --undo-log "$UNDO_LOG"

grep -q "lives in Munich" "$VAULT/wiki/replace.md" || fail "replace: new content not written"
grep -q "lives in Berlin" "$VAULT/wiki/replace.md" && fail "replace: old content still present"
echo "PASS: replace swaps an existing line"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_vault_writer.sh`
Expected: FAIL — `vault-writer.sh` dies on `unknown arg: --mode` (script exits non-zero before the assertion), or the old line is still present.

- [ ] **Step 3: Add arg parsing + validation in `scripts/vault-writer.sh`**

After the existing variable declarations (the block ending at `UPDATE_INDEX=1`, around line 29), add:

```bash
MODE="append"
OLD_CONTENT=""
```

In the `while`/`case` arg loop, add these two cases before the `*) die ...` line:

```bash
    --mode) MODE="$2"; shift 2 ;;
    --old-content) OLD_CONTENT="$2"; shift 2 ;;
```

After the existing required-arg checks (the block ending with the `[ -d "$VAULT" ] || die ...` line, around line 51), add:

```bash
case "$MODE" in
  append|replace|stale) ;;
  *) die "invalid --mode: $MODE (expected append|replace|stale)" ;;
esac
if [ "$MODE" != "append" ]; then
  [ -n "$OLD_CONTENT" ] || die "--mode $MODE requires --old-content"
fi
```

- [ ] **Step 4: Implement the `replace` branch**

In the "append content under section" region, wrap the existing append logic so it only runs for `append` mode, and add the replace/stale branch. Replace the current block that starts at `APPEND_LINE="- $CONTENT"` (line 86) and ends at its closing `fi` (line 122) with:

```bash
APPEND_LINE="- $CONTENT"

if [ "$MODE" = "append" ]; then
  if grep -Fxq -- "$APPEND_LINE" "$PAGE_PATH"; then
    : # already present, no-op
  else
    if grep -Fxq -- "## $SECTION" "$PAGE_PATH"; then
      awk -v section="## $SECTION" -v newline="$APPEND_LINE" '
        BEGIN { inserted = 0; in_section = 0 }
        {
          if ($0 == section) { print; in_section = 1; next }
          if (in_section && !inserted && /^## / && $0 != section) {
            print newline
            print ""
            inserted = 1
            in_section = 0
          }
          print
        }
        END {
          if (in_section && !inserted) {
            print newline
          }
        }
      ' "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
    else
      {
        echo ""
        echo "## $SECTION"
        echo ""
        echo "$APPEND_LINE"
      } >> "$PAGE_PATH"
    fi
  fi
else
  # replace / stale: edit an existing exact line "- $OLD_CONTENT"
  OLD_LINE="- $OLD_CONTENT"
  if [ "$MODE" = "stale" ]; then
    FINAL_CONTENT="~~${OLD_CONTENT}~~ <!-- superseded $(date +%F) -->"
  else
    FINAL_CONTENT="$CONTENT"
  fi
  NEW_LINE="- $FINAL_CONTENT"

  if grep -Fxq -- "$OLD_LINE" "$PAGE_PATH"; then
    awk -v old="$OLD_LINE" -v new="$NEW_LINE" '
      { if ($0 == old) print new; else print }
    ' "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
  elif grep -Fxq -- "$NEW_LINE" "$PAGE_PATH"; then
    : # already in target state — idempotent no-op
  else
    die "replace: old content not found in $PAGE: $OLD_CONTENT"
  fi
fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_vault_writer.sh`
Expected: PASS through "PASS: replace swaps an existing line" (Tests 1–7 still PASS).

- [ ] **Step 6: Commit**

```bash
git add scripts/vault-writer.sh tests/test_vault_writer.sh
git commit -m "feat(vault-writer): add replace mode to swap an existing line"
```

---

### Task 2: `replace` is idempotent and fails loudly when the old line is missing

**Files:**
- Modify: `tests/test_vault_writer.sh`
- (No `vault-writer.sh` change — Task 1's guards already implement this; this task verifies them.)

- [ ] **Step 1: Write the failing test** — append before the final `echo "All vault-writer.sh tests passed."`:

```bash
# Test 9: replace is idempotent (re-running the same replace is a no-op)
"$WRITER" --vault "$VAULT" --page "wiki/replace.md" --section "Status" \
  --mode replace --old-content "lives in Berlin" \
  --content "lives in Munich (moved 2026-06)" --undo-log "$UNDO_LOG"
COUNT=$(grep -c "lives in Munich" "$VAULT/wiki/replace.md")
[ "$COUNT" -eq 1 ] || fail "replace not idempotent (count=$COUNT, expected 1)"
echo "PASS: replace is idempotent"

# Test 10: replace fails loudly when neither old nor new content is present
if "$WRITER" --vault "$VAULT" --page "wiki/replace.md" --section "Status" \
     --mode replace --old-content "nonexistent fact" \
     --content "whatever" --undo-log "$UNDO_LOG" 2>/dev/null; then
  fail "replace should exit non-zero when old content is absent"
fi
echo "PASS: replace fails when old content missing"
```

- [ ] **Step 2: Run test to verify it passes** (guards from Task 1 already cover this)

Run: `bash tests/test_vault_writer.sh`
Expected: PASS through "PASS: replace fails when old content missing".

If Test 9 or 10 fails, the guards in Task 1 Step 4 are wrong — fix them there (the `elif grep -Fxq -- "$NEW_LINE"` no-op branch handles idempotency; the `else die` handles the missing case), then re-run.

- [ ] **Step 3: Commit**

```bash
git add tests/test_vault_writer.sh
git commit -m "test(vault-writer): cover replace idempotency and missing-old failure"
```

---

### Task 3: `replace` writes a reversible undo entry; `apply-undo` restores the old line

**Files:**
- Modify: `scripts/vault-writer.sh` (undo log entry for replace/stale)
- Modify: `scripts/apply-undo.sh` (reverse a `replace` action)
- Test: `tests/test_vault_writer.sh`

- [ ] **Step 1: Write the failing test** — append before the final echo:

```bash
# Test 11: replace is reversible via apply-undo
UNDO_RT="$VAULT/undo-roundtrip.jsonl"
cat > "$VAULT/wiki/roundtrip.md" <<'EOF'
# Roundtrip

## Status
- status alpha
EOF

"$WRITER" --vault "$VAULT" --page "wiki/roundtrip.md" --section "Status" \
  --mode replace --old-content "status alpha" \
  --content "status beta" --undo-log "$UNDO_RT"

grep -q "replace" "$UNDO_RT" || fail "replace: undo entry not action=replace"

bash "$SCRIPT_DIR/../scripts/apply-undo.sh" "$UNDO_RT" >/dev/null

grep -q "^- status alpha$" "$VAULT/wiki/roundtrip.md" || fail "undo did not restore old line"
grep -q "status beta" "$VAULT/wiki/roundtrip.md" && fail "undo did not remove the replacement line"
echo "PASS: replace round-trips through apply-undo"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_vault_writer.sh`
Expected: FAIL — the undo log has no `replace` entry yet (vault-writer still only logs `append`), so `apply-undo` skips it and the old line is not restored.

- [ ] **Step 3: Add the replace/stale undo entry in `scripts/vault-writer.sh`**

In the undo-log block (the `if [ -n "$UNDO_LOG" ]; then ...` region, around lines 124–133), the current code unconditionally logs an `append` entry. Replace that block's body so the action matches the mode. Replace lines 125–133 (from `if [ -n "$UNDO_LOG" ]; then` through its closing `fi`) with:

```bash
if [ -n "$UNDO_LOG" ]; then
  mkdir -p "$(dirname "$UNDO_LOG")"
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ESC_SECTION=$(printf '%s' "$SECTION" | sed 's/\\/\\\\/g; s/"/\\"/g')
  if [ "$MODE" = "append" ]; then
    ESC_CONTENT=$(printf '%s' "$CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"timestamp":"%s","vault":"%s","page":"%s","section":"%s","content":"%s","action":"append"}\n' \
      "$TS" "$VAULT" "$PAGE" "$ESC_SECTION" "$ESC_CONTENT" >> "$UNDO_LOG"
  else
    ESC_OLD=$(printf '%s' "$OLD_CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g')
    ESC_NEW=$(printf '%s' "$FINAL_CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"timestamp":"%s","vault":"%s","page":"%s","section":"%s","old_content":"%s","content":"%s","action":"replace"}\n' \
      "$TS" "$VAULT" "$PAGE" "$ESC_SECTION" "$ESC_OLD" "$ESC_NEW" >> "$UNDO_LOG"
  fi
fi
```

Note: `$FINAL_CONTENT` is set in the replace/stale branch from Task 1; for `append` mode it is unused.

- [ ] **Step 4: Add the `replace)` case in `scripts/apply-undo.sh`**

In the `case "$ACTION" in` block, add this case after the existing `append)` case (after its `;;`, before `index_append)`):

```bash
    replace)
      VAULT=$(echo "$line" | jq -r '.vault')
      PAGE=$(echo "$line" | jq -r '.page')
      OLD=$(echo "$line" | jq -r '.old_content')
      NEW=$(echo "$line" | jq -r '.content')
      PAGE_PATH="$VAULT/$PAGE"
      if [ -f "$PAGE_PATH" ]; then
        awk -v old="- $NEW" -v new="- $OLD" '
          { if ($0 == old) print new; else print }
        ' "$PAGE_PATH" > "$PAGE_PATH.tmp" && mv "$PAGE_PATH.tmp" "$PAGE_PATH"
        REVERTED=$((REVERTED + 1))
      else
        SKIPPED=$((SKIPPED + 1))
      fi
      ;;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_vault_writer.sh`
Expected: PASS through "PASS: replace round-trips through apply-undo".

- [ ] **Step 6: Run the existing undo test to confirm no regression**

Run: `bash tests/test_undo.sh`
Expected: PASS (append-undo behavior unchanged).

- [ ] **Step 7: Commit**

```bash
git add scripts/vault-writer.sh scripts/apply-undo.sh tests/test_vault_writer.sh
git commit -m "feat(vault-writer,apply-undo): reversible replace via undo log"
```

---

### Task 4: `stale` mode annotates an existing line as superseded (reversible)

**Files:**
- Test: `tests/test_vault_writer.sh`
- (No new `vault-writer.sh`/`apply-undo.sh` code — the `stale` branch and undo entry from Tasks 1 & 3 already implement it; this task verifies end-to-end.)

- [ ] **Step 1: Write the failing test** — append before the final echo:

```bash
# Test 12: stale mode strikes through the old line and marks it superseded
cat > "$VAULT/wiki/stale.md" <<'EOF'
# Stale

## Priorities
- current internship at Aximon
EOF

"$WRITER" --vault "$VAULT" --page "wiki/stale.md" --section "Priorities" \
  --mode stale --old-content "current internship at Aximon" \
  --content "n/a" --undo-log "$VAULT/undo-stale.jsonl"

grep -q "~~current internship at Aximon~~" "$VAULT/wiki/stale.md" || fail "stale: line not struck through"
grep -q "superseded" "$VAULT/wiki/stale.md" || fail "stale: superseded marker missing"
echo "PASS: stale annotates the old line"

# And it reverses cleanly
bash "$SCRIPT_DIR/../scripts/apply-undo.sh" "$VAULT/undo-stale.jsonl" >/dev/null
grep -q "^- current internship at Aximon$" "$VAULT/wiki/stale.md" || fail "stale: undo did not restore original"
echo "PASS: stale round-trips through apply-undo"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_vault_writer.sh`
Expected: PASS through "PASS: stale round-trips through apply-undo".

If it fails: confirm the `stale` branch in Task 1 Step 4 sets `FINAL_CONTENT="~~${OLD_CONTENT}~~ <!-- superseded $(date +%F) -->"` and that the undo entry (Task 3) logs `content="$FINAL_CONTENT"`.

- [ ] **Step 3: Run the full suite + commit**

Run: `for t in tests/test_*.sh; do echo "== $t =="; bash "$t" || break; done`
Expected: every test file ends with its "All ... passed." line; no `FAIL:`.

```bash
git add tests/test_vault_writer.sh
git commit -m "test(vault-writer): cover stale annotate + undo round-trip"
```

---

## Self-Review

**Spec coverage (this slice):** The spec's §5 "New" item *"vault-writer must learn to edit/replace/mark-stale, not just append"* and §7's `SUPERSEDES`/`CONTRADICTS` actions both require exactly: replace a line (Task 1), keep it safe/idempotent (Task 2), keep it reversible (Task 3), and annotate-as-stale (Task 4). Routing/reconciliation that *decides* when to call these is out of scope here — that's Plans 2 & 3.

**Placeholder scan:** No TBD/TODO. Every code step shows complete code. Test bodies are concrete, with real assertions and expected output.

**Type/contract consistency:**
- Flags: `--mode` (`append|replace|stale`) and `--old-content` — used identically in tests and in vault-writer.
- Undo JSONL contract: replace/stale write `{"action":"replace","old_content":...,"content":...}`; `apply-undo.sh` reads exactly `.old_content` and `.content` for `action=replace`. Field names match.
- `$FINAL_CONTENT` is defined in the replace/stale branch (Task 1) and read by the undo block (Task 3) — same variable name; append mode never reads it.
- On-page line format `- <content>` is consistent across write (`NEW_LINE`), undo (`- $NEW` / `- $OLD`), and assertions (`^- ...$`).

**Back-compat:** append mode is the default and its code path is byte-for-byte the original; Tests 1–7 and `test_undo.sh` must still pass (verified in Task 3 Step 6 and Task 4 Step 3).

---

## Execution Handoff

Plan complete and saved to `PLAN-01-vault-writer-edit-2026-06-03.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session via executing-plans, batched with checkpoints.

Which approach?
