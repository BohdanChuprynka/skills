#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$SCRIPT_DIR/../scripts/build-nav-context.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fixture: a minimal multi-vault tmp dir mimicking the real layout
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d "/tmp/dream-nav-test-XXXXXX")
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Helper: create a mock vault (no CLAUDE.md needed; purpose comes from config.toml)
make_vault() {
  local name="$1"
  local vroot="$TMPDIR_ROOT/$name"
  mkdir -p "$vroot/wiki"
  # wiki/index.md
  printf "# %s Wiki Index\n\n[[page-a]] — first page\n[[page-b]] — second page\n" "$name" > "$vroot/wiki/index.md"
  # two wiki pages on disk
  touch "$vroot/wiki/page-a.md" "$vroot/wiki/page-b.md"
}

make_vault "me"
make_vault "projects"
make_vault "gym-sprint"
make_vault "setup"
make_vault "personal-notes"
make_vault "work"

# Write a TOML config fixture (mirrors the real ~/.claude/dream-skill/config.toml format)
CONFIG="$TMPDIR_ROOT/config.toml"
cat > "$CONFIG" <<TOML
reports_dir = "$TMPDIR_ROOT/dream-reports"

[vaults.me]
root        = "$TMPDIR_ROOT/me"
description = "Identity, skills, experience, education, career, goals"

[vaults.projects]
root        = "$TMPDIR_ROOT/projects"
description = "Repositories, codebases, architecture, tech stack"

[vaults.gym-sprint]
root        = "$TMPDIR_ROOT/gym-sprint"
description = "Fitness, workouts, running, body composition, nutrition"

[vaults.setup]
root        = "$TMPDIR_ROOT/setup"
description = "App-level configuration, keyboard shortcuts, dotfiles"

[vaults.personal-notes]
root        = "$TMPDIR_ROOT/personal-notes"
description = "School subjects, journal, references, atomic notes"

[vaults.work]
root        = "$TMPDIR_ROOT/work"
description = "Sprint-cycle outreaches, pipelines, deals, playbooks"
TOML

# ---------------------------------------------------------------------------
# Test 1: script exits 0 and produces non-empty output
# ---------------------------------------------------------------------------
OUTPUT=$("$BUILDER" --config "$CONFIG" 2>&1)
[ -n "$OUTPUT" ] || fail "build-nav-context: empty output"
echo "PASS: script exits 0 and output is non-empty"

# ---------------------------------------------------------------------------
# Test 2: output contains all 6 vault names
# ---------------------------------------------------------------------------
for v in me projects gym-sprint setup personal-notes work; do
  echo "$OUTPUT" | grep -q "$v" || fail "vault '$v' missing from output"
done
echo "PASS: all 6 vault names present in output"

# ---------------------------------------------------------------------------
# Test 3: output contains purpose strings from config.toml description field
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "Identity, skills" || fail "me vault purpose line missing"
echo "$OUTPUT" | grep -q "Repositories, codebases" || fail "projects vault purpose line missing"
echo "PASS: config.toml description strings present"

# ---------------------------------------------------------------------------
# Test 4: output contains index entries
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "page-a" || fail "index entry 'page-a' not in output"
echo "$OUTPUT" | grep -q "page-b" || fail "index entry 'page-b' not in output"
echo "PASS: wiki/index.md entries present"

# ---------------------------------------------------------------------------
# Test 5: output contains dir-scan entries (find output)
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "page-a.md" || fail "dir-scan 'page-a.md' not in output"
echo "PASS: dir-scan entries present"

# ---------------------------------------------------------------------------
# Test 6: output is bounded (< 8000 chars, enforcing ~2k token ceiling)
# ---------------------------------------------------------------------------
CHARCOUNT=${#OUTPUT}
[ "$CHARCOUNT" -lt 8000 ] || fail "output too large ($CHARCOUNT chars, limit 8000)"
echo "PASS: output within 8000-char ceiling"

# ---------------------------------------------------------------------------
# Test 7: missing vault root → warning on stderr, not hard failure
# ---------------------------------------------------------------------------
MISSING_CONFIG=$(mktemp "/tmp/missing-conf-XXXXXX.toml")
cat > "$MISSING_CONFIG" <<TOML2
[vaults.ghost]
root        = "/nonexistent/path/ghost"
description = "Does not exist"
TOML2
WARN_OUT=$("$BUILDER" --config "$MISSING_CONFIG" 2>&1) || true
echo "$WARN_OUT" | grep -qi "warn\|skip\|missing\|not found" \
  || fail "missing vault root should emit a warning"
echo "PASS: missing vault root produces warning, not crash"
rm -f "$MISSING_CONFIG"

# ---------------------------------------------------------------------------
# Test 8: output has a clearly delimited header block
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "NAV-CONTEXT" || fail "output missing NAV-CONTEXT delimiter"
echo "PASS: NAV-CONTEXT delimiter present"

echo "All build-nav-context.sh tests passed."
