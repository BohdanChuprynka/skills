# dream-skill v0.2 — Auto-on-close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v0.1's multi-source map-reduce reconciliation with a per-conversation auto-on-close architecture. SessionEnd hook fires when user closes Claude Code → headless `claude -p "/dream-skill --auto <transcript>"` extracts info-gain content → confident facts written to vault directly → uncertain/destructive/brainstormed facts queued for manual review.

**Architecture:**
1. **Plugin-shipped SessionEnd hook** (`hooks/hooks.json`) auto-installs on `/plugin install`. Fires on close.
2. **Trigger script** counts user-turn messages in transcript. If ≥5, spawns headless `claude -p` in background.
3. **Headless skill invocation** runs the same `dream-skill` SKILL.md in `--auto` mode: regex pre-strip transcript, LLM filters for info-gain, routes facts.
4. **Confident facts** → appended to vault page via harvested target-file resolution + index update logic.
5. **Uncertain/destructive/brainstormed facts** → appended to `~/.claude/dream-queue/pending.md`.
6. **Manual `/dream-skill`** sweeps queue fact-by-fact with user confirmation.
7. **`/dream-skill --reconcile`** preserved escape hatch (later, optional) for occasional full-vault audit.

**Tech Stack:** Bash, Claude Code plugin hooks (`hooks/hooks.json`), jq (transcript JSONL parsing), Python (optional, for tiktoken token counts), `claude -p` headless mode.

**File structure (final):**

```
dream-skill/
├── .claude-plugin/
│   ├── plugin.json          # bumped to 0.2.0, declares hooks ref
│   └── marketplace.json     # bumped to 0.2.0
├── hooks/
│   └── hooks.json           # SessionEnd → trigger.sh
├── scripts/
│   ├── trigger.sh           # gates on message count, dispatches headless
│   ├── preprocess.sh        # regex strip transcript noise
│   ├── vault-writer.sh      # add-only vault writes + index update
│   ├── queue.sh             # queue file management
│   ├── apply-undo.sh        # rollback for auto-written facts
│   └── count_tokens.py      # tiktoken + byte fallback (harvested)
├── skills/dream-skill/
│   └── SKILL.md             # branches: --auto, manual, --reconcile
├── tests/
│   ├── fixtures/            # sample transcript JSONL files
│   ├── test_trigger.sh      # gating + dispatch tests
│   ├── test_preprocess.sh   # strip rules tests
│   └── test_e2e.sh          # full pipeline against fixture
├── config/
│   ├── vault-paths.toml     # gitignored
│   └── vault-paths.example.toml
├── HARVEST.md               # reuse notes (already saved)
├── PLAN.md                  # this file
└── README.md                # rewritten for v0.2
```

**Execution mode:** No worktree. Work directly in main. Each task = one commit so GitHub activity reflects progress.

---

## Phase 0 — Reset

### Task 0.1: Trash old skill content, preserve plugin manifest

**Files:**
- Delete: `dream-skill/skills/dream-skill/*` (all old SKILL.md, scripts, docs)
- Delete: `dream-skill/docs/`, `dream-skill/setup.sh`, `dream-skill/CHANGELOG.md`
- Delete: `dream-skill/tests/*` (old test suite for old arch)
- Delete: `dream-skill/config/*` (old TOML schema for old arch)
- Delete: `dream-skill/README.md` (rewritten in Task 5.1)
- **Preserve:** `dream-skill/.claude-plugin/plugin.json`, `dream-skill/.claude-plugin/marketplace.json`, `dream-skill/HARVEST.md`, `dream-skill/PLAN.md`
- **Preserve:** `dream-skill/LICENSE` if present

- [ ] **Step 1: Verify what will be preserved before destructive delete**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
ls -la .claude-plugin/ HARVEST.md PLAN.md 2>&1
```

Expected: plugin.json, marketplace.json, HARVEST.md, PLAN.md all present.

- [ ] **Step 2: Delete old skill content (manifest preserved)**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills/dream-skill
rm -rf skills docs tests config setup.sh CHANGELOG.md README.md
ls -la
```

Expected output: only `.claude-plugin/`, `HARVEST.md`, `PLAN.md`, `LICENSE` (if present), `.gitignore` (if present) remain.

- [ ] **Step 3: Commit the reset**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills
git add -A dream-skill/
git status --short dream-skill/
git commit -m "feat(dream-skill)!: reset to v0.2 — auto-on-close architecture

BREAKING: v0.1 multi-source MCP reconciliation removed.
v0.2 rebuild begins. See dream-skill/HARVEST.md for ported patterns,
dream-skill/PLAN.md for build steps."
```

---

## Phase 1 — Plugin scaffolding + hook

### Task 1.1: Write hooks/hooks.json (SessionEnd → trigger.sh)

**Files:**
- Create: `dream-skill/hooks/hooks.json`

- [ ] **Step 1: Write hook config**

```bash
mkdir -p dream-skill/hooks
```

```json
{
  "hooks": {
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

- [ ] **Step 2: Verify JSON parses**

```bash
jq . dream-skill/hooks/hooks.json
```

Expected: re-prints the JSON without error.

### Task 1.2: Update plugin.json to declare hooks

**Files:**
- Modify: `dream-skill/.claude-plugin/plugin.json`

- [ ] **Step 1: Add `hooks` field + bump version**

Add `"hooks": "./hooks/hooks.json"` and bump `"version": "0.1.0"` → `"version": "0.2.0"`.

- [ ] **Step 2: Verify**

```bash
jq . dream-skill/.claude-plugin/plugin.json
```

Expected: shows new `hooks` field + version 0.2.0.

### Task 1.3: Write scripts/trigger.sh (gating + dispatch)

**Files:**
- Create: `dream-skill/scripts/trigger.sh`
- Create: `dream-skill/tests/fixtures/transcript-3msg.jsonl`
- Create: `dream-skill/tests/fixtures/transcript-15msg.jsonl`
- Create: `dream-skill/tests/test_trigger.sh`

**Behavior contract:**
- Reads transcript path from `$CLAUDE_TRANSCRIPT_PATH` (or computes from session id + project slug)
- Counts user-role messages in transcript
- If count < 10 → exit 0 silently
- If count ≥ 10 → spawn `claude -p "/dream-skill --auto <transcript-path>"` in background, log dispatch to `~/.claude/dream-skill/trigger.log`, exit 0
- Robust: `set -euo pipefail`, no destructive ops, idempotent

- [ ] **Step 1: Write failing test first (TDD)**

`dream-skill/tests/test_trigger.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"
TRIGGER="$(cd "$(dirname "$0")/../scripts" && pwd)/trigger.sh"

# Override dispatch to a no-op stub for tests
export DREAM_DISPATCH_STUB=1
export DREAM_LOG=/tmp/dream-test-trigger.log
rm -f "$DREAM_LOG"

# Test 1: below threshold → no dispatch
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-3msg.jsonl" "$TRIGGER"
if grep -q DISPATCH "$DREAM_LOG" 2>/dev/null; then
  echo "FAIL: 3-message fixture triggered dispatch"
  exit 1
fi
echo "PASS: 3-message fixture did not dispatch"

# Test 2: at/above threshold → dispatch
CLAUDE_TRANSCRIPT_PATH="$FIXTURE_DIR/transcript-15msg.jsonl" "$TRIGGER"
if ! grep -q DISPATCH "$DREAM_LOG" 2>/dev/null; then
  echo "FAIL: 15-message fixture did not dispatch"
  exit 1
fi
echo "PASS: 15-message fixture dispatched"
```

- [ ] **Step 2: Generate fixtures**

```bash
mkdir -p dream-skill/tests/fixtures
# 3 user messages
for i in 1 2 3; do
  echo "{\"role\":\"user\",\"content\":\"msg $i\"}" >> dream-skill/tests/fixtures/transcript-3msg.jsonl
done
# 15 user messages
for i in $(seq 1 15); do
  echo "{\"role\":\"user\",\"content\":\"msg $i\"}" >> dream-skill/tests/fixtures/transcript-15msg.jsonl
done
```

- [ ] **Step 3: Run test, expect FAIL (script doesn't exist)**

```bash
chmod +x dream-skill/tests/test_trigger.sh
dream-skill/tests/test_trigger.sh
```

Expected: errors because `trigger.sh` doesn't exist.

- [ ] **Step 4: Implement trigger.sh**

```bash
mkdir -p dream-skill/scripts
```

```bash
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${DREAM_LOG:-$HOME/.claude/dream-skill/trigger.log}"
mkdir -p "$(dirname "$LOG_FILE")"

# Resolve transcript path
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "$(date -Iseconds) SKIP no-transcript" >> "$LOG_FILE"
  exit 0
fi

# Count user-role messages
USER_MSGS=$(grep -c '"role":"user"' "$TRANSCRIPT" 2>/dev/null || echo 0)

THRESHOLD=10
if [ "$USER_MSGS" -lt "$THRESHOLD" ]; then
  echo "$(date -Iseconds) SKIP below-threshold count=$USER_MSGS" >> "$LOG_FILE"
  exit 0
fi

echo "$(date -Iseconds) DISPATCH count=$USER_MSGS transcript=$TRANSCRIPT" >> "$LOG_FILE"

# Test stub: just log, don't actually spawn claude
if [ "${DREAM_DISPATCH_STUB:-0}" = "1" ]; then
  exit 0
fi

# Background-spawn the headless invocation
nohup claude -p "/dream-skill --auto $TRANSCRIPT" > /dev/null 2>&1 &
disown
exit 0
```

- [ ] **Step 5: Run test, expect PASS**

```bash
chmod +x dream-skill/scripts/trigger.sh
dream-skill/tests/test_trigger.sh
```

Expected: both PASS lines printed.

- [ ] **Step 6: Commit**

```bash
cd /Users/bohdan/Documents/IT-Work/Projects/IT/skills
git add dream-skill/hooks/ dream-skill/scripts/trigger.sh dream-skill/tests/ dream-skill/.claude-plugin/plugin.json
git commit -m "feat(dream-skill): SessionEnd hook + trigger script with threshold gating

Hook auto-installs via plugin manifest (.claude-plugin/plugin.json hooks
field → hooks/hooks.json). Trigger script counts user messages; ≥5 →
dispatch headless claude -p. Tests cover below/above threshold."
```

---

## Phase 2 — Transcript preprocessor

### Task 2.1: Write scripts/preprocess.sh (regex strip noise)

**Files:**
- Create: `dream-skill/scripts/preprocess.sh`
- Create: `dream-skill/tests/fixtures/transcript-noisy.jsonl`
- Create: `dream-skill/tests/test_preprocess.sh`

**Behavior contract:** Reads a Claude Code transcript JSONL file; emits a stripped plain-text version on stdout containing only:
- User message text (always)
- Assistant message text (always, often summarizes user decisions)
- Skipped: tool_use blocks, tool_result blocks, `<system-reminder>` content, MCP raw outputs ≥20 lines, hook output blocks

LLM-judgment filtering (code-vs-concept, Q&A signal, brainstormed ideas) happens in the SKILL.md execution, not here.

- [ ] **Step 1: Write a noisy fixture transcript**

```bash
cat > dream-skill/tests/fixtures/transcript-noisy.jsonl <<'EOF'
{"role":"user","content":[{"type":"text","text":"Help me plan tomorrow"}]}
{"role":"assistant","content":[{"type":"text","text":"Sure. Calendar shows 3 events."},{"type":"tool_use","name":"calendar","id":"abc","input":{}}]}
{"role":"user","content":[{"type":"tool_result","tool_use_id":"abc","content":"[10000 lines of MCP output]"}]}
{"role":"user","content":[{"type":"text","text":"<system-reminder>some hook text</system-reminder>Schedule 9am block for project X."}]}
{"role":"assistant","content":[{"type":"text","text":"Locked in 9am block for project X."}]}
EOF
```

- [ ] **Step 2: Write failing test**

`tests/test_preprocess.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PREP="$(cd "$(dirname "$0")/../scripts" && pwd)/preprocess.sh"
FIX="$(cd "$(dirname "$0")/fixtures" && pwd)/transcript-noisy.jsonl"

OUT=$("$PREP" "$FIX")

# Must keep meaningful user/assistant text
echo "$OUT" | grep -q "Help me plan tomorrow" || { echo "FAIL: missing user text"; exit 1; }
echo "$OUT" | grep -q "Schedule 9am block for project X" || { echo "FAIL: missing user text 2"; exit 1; }
echo "$OUT" | grep -q "Locked in 9am block" || { echo "FAIL: missing assistant text"; exit 1; }

# Must strip tool results, system reminders, raw MCP output
if echo "$OUT" | grep -q "10000 lines of MCP output"; then echo "FAIL: tool_result leaked"; exit 1; fi
if echo "$OUT" | grep -q "system-reminder"; then echo "FAIL: system-reminder leaked"; exit 1; fi
if echo "$OUT" | grep -q "some hook text"; then echo "FAIL: hook content leaked"; exit 1; fi

echo "PASS: preprocess strips noise, keeps text"
```

- [ ] **Step 3: Implement preprocess.sh (jq-based)**

```bash
#!/usr/bin/env bash
set -euo pipefail
TRANSCRIPT="${1:?usage: preprocess.sh <transcript.jsonl>}"
[ -f "$TRANSCRIPT" ] || { echo "no such file: $TRANSCRIPT" >&2; exit 1; }

# Per-line: extract text-only content, skip tool_use/tool_result blocks,
# strip system-reminder tags from any remaining text.
jq -r '
  .content
  | if type=="string" then [{type:"text",text:.}] else . end
  | map(select(.type == "text"))
  | map(.text)
  | join("\n")
' "$TRANSCRIPT" 2>/dev/null \
| sed -E 's|<system-reminder>[^<]*</system-reminder>||g' \
| grep -v '^$'
```

- [ ] **Step 4: Run test, expect PASS**

```bash
chmod +x dream-skill/scripts/preprocess.sh dream-skill/tests/test_preprocess.sh
dream-skill/tests/test_preprocess.sh
```

Expected: `PASS: preprocess strips noise, keeps text`.

- [ ] **Step 5: Commit**

```bash
git add dream-skill/scripts/preprocess.sh dream-skill/tests/test_preprocess.sh dream-skill/tests/fixtures/transcript-noisy.jsonl
git commit -m "feat(dream-skill): transcript preprocessor strips tool/hook/MCP noise

Keeps user + assistant text content only. LLM-judgment filtering for
code-vs-concept and Q&A signal happens in SKILL.md, not here."
```

---

## Phase 3 — Skill spec (the LLM brain)

### Task 3.1: Write skills/dream-skill/SKILL.md (auto/manual/reconcile modes)

**Files:**
- Create: `dream-skill/skills/dream-skill/SKILL.md`

**Content outline:**

- Frontmatter: name, description (triggers), version 0.2.0
- Mode dispatch: argv-based — `--auto <transcript>`, no-arg = manual queue review, `--reconcile` = full audit (deferred to later version)
- **Auto mode flow** (each step described as instructions to the LLM):
  1. Read preprocessed transcript (script call)
  2. Read vault CLAUDE.md files at known paths
  3. For each candidate fact: classify info-gain bucket
     - **High confidence + additive**: new project, new role, new deadline, new preference, new fact about user → append to vault page via `vault-writer.sh`
     - **General-knowledge Q&A**: drop UNLESS reveals user signal (out-of-domain question = keep as "user explored X today")
     - **Code blocks**: drop unless surrounding prose discusses concept; if conceptual → summarize the concept, not the code
     - **Brainstormed-not-decided ideas**: route to queue under `## Brainstormed ideas` section
     - **Destructive edit** (contradicts vault fact): route to queue under `## Destructive edits`
     - **Uncertain / medium confidence**: route to queue under `## Uncertain facts`
  4. Append each routing decision to `~/.claude/dream-skill/log/<YYYY-MM-DD>.md`
- **Manual mode flow**:
  1. Read `~/.claude/dream-queue/pending.md`
  2. For each queued entry, present to user with evidence + proposed action
  3. Accept: yes / edit / skip / discard
  4. Apply via `vault-writer.sh` or discard
  5. Clear processed entries from queue
- **Reconcile mode**: stub for v0.3 — write "not yet implemented in v0.2" message

- [ ] **Step 1: Write SKILL.md with full mode-dispatch spec**

(Full content drafted during execution. Reference HARVEST.md for proposal-evidence-confidence schema and target-file resolution.)

- [ ] **Step 2: Manual sanity test**

Open Claude Code in this dir, type `/dream-skill --help` and verify the LLM understands the mode dispatch.

- [ ] **Step 3: Commit**

```bash
git add dream-skill/skills/dream-skill/SKILL.md
git commit -m "feat(dream-skill): SKILL.md with auto/manual/reconcile mode dispatch

Auto mode: preprocessed transcript → LLM filters by info-gain bucket →
confident facts written, uncertain/destructive/brainstormed queued.
Manual mode: sweeps queue fact-by-fact with user confirmation.
Reconcile stub for v0.3."
```

---

## Phase 4 — Vault writer + queue

### Task 4.1: Write scripts/vault-writer.sh (add-only writes + index update)

**Files:**
- Create: `dream-skill/scripts/vault-writer.sh`
- Create: `dream-skill/tests/fixtures/mock-vault/wiki/index.md`
- Create: `dream-skill/tests/fixtures/mock-vault/wiki/test-page.md`
- Create: `dream-skill/tests/test_vault_writer.sh`

**Behavior contract** (ported from HARVEST.md sections 1, 2):
- Args: `--vault <root> --page <relative-path> --section <header> --content <text> [--undo-log <path>]`
- Add-only: append content under matching `## Section` header; create section if absent; never delete or overwrite
- Index update: auto-discover `<vault>/wiki/index.md` → append `[label](page.md) — description` if not already linked (idempotent on both markdown and Obsidian `[[wikilink]]` forms)
- Undo log: append JSONL entry `{date, page, section, content, index_edit}` to `--undo-log` if provided

- [ ] **Step 1: Write failing tests**

Tests cover: append to existing section, create new section, idempotent re-append (no double-add), index updated, idempotent index (existing link → no-op).

- [ ] **Step 2: Implement vault-writer.sh**

Pure bash + sed/awk. No external deps beyond coreutils.

- [ ] **Step 3: Run tests, expect PASS**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(dream-skill): vault-writer with add-only writes + idempotent index updates

Ports target-file resolution and index.md auto-discovery from v0.1 (see
HARVEST.md). Add-only by design: auto mode never overwrites; destructive
edits go to queue for manual review."
```

### Task 4.2: Write scripts/queue.sh (queue file management)

**Files:**
- Create: `dream-skill/scripts/queue.sh`
- Create: `dream-skill/tests/test_queue.sh`

**Behavior contract:**
- Args: `append --bucket <destructive|uncertain|brainstormed> --title <t> --evidence <e> --confidence <c> --target <vault-path>`
- Queue file: `~/.claude/dream-queue/pending.md` (auto-created)
- Sections: `## Destructive edits`, `## Uncertain facts`, `## Brainstormed ideas`
- Each entry: structured markdown matching the proposal-evidence-confidence schema (HARVEST.md §1)
- `list` subcommand: dumps queue grouped by bucket
- `clear --entry-id <id>` subcommand: removes a single entry by hash

- [ ] **Step 1–4: TDD as above**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(dream-skill): queue manager for deferred-decision facts

Uses proposal-evidence-confidence schema (HARVEST.md §1). Queue lives at
~/.claude/dream-queue/pending.md, survives plugin updates. Three buckets:
destructive, uncertain, brainstormed."
```

### Task 4.3: Write scripts/apply-undo.sh (rollback)

**Files:**
- Create: `dream-skill/scripts/apply-undo.sh`
- Create: `dream-skill/tests/test_undo.sh`

**Behavior contract:**
- Args: `<undo-log-path>` OR `--date <YYYY-MM-DD>` (resolves to today's log)
- Reads JSONL undo entries in reverse order
- For each: removes the appended content from the page (and index link if applicable)
- Prints a summary of what was reverted

- [ ] **Step 1–4: TDD as above**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(dream-skill): apply-undo for reversing auto-mode writes

Required escape hatch: auto mode writes without user confirmation, so undo
must work fact-by-fact or full-session."
```

### Task 4.4: Port count_tokens.py (harvested utility)

**Files:**
- Create: `dream-skill/scripts/count_tokens.py`

- [ ] **Step 1: Recover from v0.1 git history**

```bash
git show 5868fcd:dream-skill/skills/dream-skill/scripts/count_tokens.py > dream-skill/scripts/count_tokens.py
```

- [ ] **Step 2: Verify it runs**

```bash
echo "hello world" | python3 dream-skill/scripts/count_tokens.py
```

Expected: prints token count (or byte-fallback count).

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(dream-skill): port count_tokens.py from v0.1 for budget gating

Cherry-pick from 5868fcd. Used by trigger.sh to skip dispatch on
unusually-short transcripts (cost guard)."
```

---

## Phase 5 — Integration + ship

### Task 5.1: End-to-end smoke test

**Files:**
- Create: `dream-skill/tests/test_e2e.sh`
- Create: `dream-skill/tests/fixtures/transcript-realistic.jsonl` (hand-authored ~15 messages with mix of decisions, code, brainstormed ideas)

**Test:**
1. Set up mock vault dir + queue dir in `/tmp/dream-e2e-$$/`
2. Run trigger.sh against fixture with env vars pointing to mocks
3. (Skip actual `claude -p` invocation — use stub mode)
4. Assert: log file created, dispatch decision logged, would-be command captured correctly
5. Separately, manually run preprocess.sh + verify expected stripped output
6. Manually verify queue + vault-writer + undo all work in isolation (already covered by per-script tests)

- [ ] **Step 1–3: Write fixtures + test + run**

- [ ] **Step 4: Commit**

```bash
git commit -m "test(dream-skill): end-to-end pipeline smoke test"
```

### Task 5.2: Rewrite README.md

**Files:**
- Create: `dream-skill/README.md`

**Content:**
- 1-line description: "Auto-record your Claude Code conversations to your Obsidian wiki."
- Why: persona model stays current without manual sync
- How it works: 3-step diagram (close Claude → headless extracts facts → confident written, rest queued)
- Install: `/plugin marketplace add BohdanChuprynka/skills` + `/plugin install dream-skill@skills-marketplace` (verify the marketplace name)
- Configuration: point `~/.dream-skill/config.toml` at vault root (or use defaults)
- Manual review: `/dream-skill` to sweep queue
- Undo: `apply-undo.sh --date <today>` to rollback auto-writes
- Privacy: nothing leaves your machine except your existing `claude -p` headless calls
- License: MIT

- [ ] **Step 1: Write README**

- [ ] **Step 2: Commit**

```bash
git commit -m "docs(dream-skill): rewrite README for v0.2 auto-on-close architecture"
```

### Task 5.3: Bump marketplace.json version + final commit

**Files:**
- Modify: `dream-skill/.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump version 0.1.0 → 0.2.0**

- [ ] **Step 2: Verify final tree structure**

```bash
find dream-skill -type f -not -path '*/node_modules*' -not -path '*/.git*' | sort
```

Expected: matches the "File structure (final)" map at top of this plan.

- [ ] **Step 3: Final commit + push**

```bash
git add dream-skill/.claude-plugin/marketplace.json
git commit -m "chore(dream-skill): bump to 0.2.0 — auto-on-close ready"
git push origin main
```

---

## Self-review checklist (run before execution)

- [ ] Every spec requirement (auto-on-close, queue, manual review, undo) maps to ≥1 task
- [ ] No "TBD" or placeholder steps without code (Task 3.1 SKILL.md content is intentionally drafted-at-execution-time — flagged explicitly)
- [ ] Each task ends in a commit (activity preserved)
- [ ] File paths consistent (`dream-skill/scripts/*` not `dream-skill/skills/dream-skill/scripts/*`)
- [ ] Tests precede implementation (TDD) for all scripts
- [ ] Plugin hook auto-installs (no manual settings.json edits required)
- [ ] No destructive writes to user vault in auto mode (add-only + undo log)
- [ ] HARVEST.md patterns referenced from tasks that use them (§1→4.2, §2→4.1, §3→4.4, §5→1.3)

---

## Execution handoff

Two options:

1. **Subagent-driven** (recommended): I dispatch a fresh `gsd-executor` or general-purpose subagent per task, review between tasks, fast iteration. Each task is self-contained.

2. **Inline execution**: I execute all tasks in this session sequentially with checkpoints between phases (Phase 0/1/2/3/4/5). Slower per-task but lower coordination overhead.

Recommend **inline** for this build because:
- Tasks are tightly sequenced (later tasks depend on earlier files)
- Total work is ~16 commits over a single coherent build
- You're watching live and can interject between phases

Tell me which approach to use, and I begin Phase 0.
