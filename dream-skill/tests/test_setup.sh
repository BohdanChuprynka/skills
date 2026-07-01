#!/usr/bin/env bash
# Test: setup.sh installs dream-skill into a temp HOME without overwriting config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SETUP="$ROOT/setup.sh"

fail() { echo "FAIL: $*"; exit 1; }

[ -x "$SETUP" ] || fail "setup.sh missing or not executable"

TMPHOME=$(mktemp -d "/tmp/dream-setup-home-XXXXXX")
FAKEBIN=$(mktemp -d "/tmp/dream-setup-bin-XXXXXX")
CACHE_FIXTURE="$ROOT/scripts/__pycache__/setup-test.pyc"
trap 'rm -rf "$TMPHOME" "$FAKEBIN"; rm -f "$CACHE_FIXTURE"; rmdir "$ROOT/scripts/__pycache__" 2>/dev/null || true' EXIT

cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex fake"
EOF
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude fake"
EOF
chmod +x "$FAKEBIN/codex" "$FAKEBIN/claude"

mkdir -p "$TMPHOME/.claude/dream-skill"
mkdir -p "$(dirname "$CACHE_FIXTURE")"
printf 'generated cache should never be installed\n' > "$CACHE_FIXTURE"
cat > "$TMPHOME/.claude/dream-skill/config.toml" <<'EOF'
reports_dir = "/tmp/existing-reports"

[vaults.existing]
root = "/tmp/existing-vault"
description = "must survive setup"
EOF

HOME="$TMPHOME" PATH="$FAKEBIN:$PATH" bash "$SETUP" >/tmp/dream-setup-test.out

test -L "$TMPHOME/.claude/skills/dream-skill" \
  || fail "Claude skill symlink not installed"
test -f "$TMPHOME/.codex/skills/dream-skill/SKILL.md" \
  || fail "Codex SKILL.md not copied"
test -x "$TMPHOME/.codex/skills/dream-skill/scripts/find-chats.sh" \
  || fail "Codex scripts/find-chats.sh missing or not executable"
test -f "$TMPHOME/.codex/skills/dream-skill/ROUTING.md" \
  || fail "Codex ROUTING.md not copied"
test -f "$TMPHOME/.codex/skills/dream-skill/requirements.txt" \
  || fail "Codex requirements.txt not copied"
test -f "$TMPHOME/.codex/skills/dream-skill/web/dream-review.html" \
  || fail "Codex review web asset not copied"
test -f "$TMPHOME/.codex/skills/dream-skill/agents/openai.yaml" \
  || fail "Codex agents/openai.yaml not copied"
test ! -e "$TMPHOME/.codex/skills/dream-skill/scripts/__pycache__" \
  || fail "Codex install copied scripts/__pycache__"

grep -q 'must survive setup' "$TMPHOME/.claude/dream-skill/config.toml" \
  || fail "existing config.toml was overwritten"

HOME="$TMPHOME" PATH="$FAKEBIN:$PATH" bash "$SETUP" >/tmp/dream-setup-test-rerun.out
grep -q 'must survive setup' "$TMPHOME/.claude/dream-skill/config.toml" \
  || fail "existing config.toml was overwritten on rerun"

TMPHOME_NO_CODEX=$(mktemp -d "/tmp/dream-setup-home-no-codex-XXXXXX")
FAKEBIN_NO_CODEX=$(mktemp -d "/tmp/dream-setup-bin-no-codex-XXXXXX")
trap 'rm -rf "$TMPHOME" "$FAKEBIN" "$TMPHOME_NO_CODEX" "$FAKEBIN_NO_CODEX"; rm -f "$CACHE_FIXTURE"; rmdir "$ROOT/scripts/__pycache__" 2>/dev/null || true' EXIT

cat > "$FAKEBIN_NO_CODEX/python3" <<'EOF'
#!/usr/bin/env bash
echo "Python 3 fake"
EOF
cat > "$FAKEBIN_NO_CODEX/jq" <<'EOF'
#!/usr/bin/env bash
echo "jq-1.7-fake"
EOF
cat > "$FAKEBIN_NO_CODEX/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude fake"
EOF
chmod +x "$FAKEBIN_NO_CODEX/python3" "$FAKEBIN_NO_CODEX/jq" "$FAKEBIN_NO_CODEX/claude"

HOME="$TMPHOME_NO_CODEX" PATH="$FAKEBIN_NO_CODEX:/bin:/usr/bin" bash "$SETUP" >/tmp/dream-setup-test-no-codex.out
test -f "$TMPHOME_NO_CODEX/.codex/skills/dream-skill/SKILL.md" \
  || fail "Codex skill should be installed even when codex is not on PATH"
grep -q 'codex is not on PATH yet' /tmp/dream-setup-test-no-codex.out \
  || fail "setup should warn when codex binary is missing"

echo "PASS: setup.sh installs Claude/Codex layout and preserves config"
echo
echo "All setup.sh tests passed."
