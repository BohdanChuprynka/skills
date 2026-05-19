#!/usr/bin/env bash
#
# doctor.sh — health check for the Codex target.

set -uo pipefail

CODEX_SKILL_DIR="$HOME/.codex/skills/calendar-plan"
CODEX_AUTO_DIR="$HOME/.codex/automations/calendar-plan"
CODEX_CONFIG="$HOME/.codex/config.toml"
failed=0
report() { printf '[%-4s] %-32s — %s\n' "$1" "$2" "$3"; [[ "$1" == "FAIL" ]] && failed=1 || true; }

if command -v codex >/dev/null 2>&1; then
  report PASS "codex CLI"              "$(codex --version 2>&1 | head -1)"
else
  report FAIL "codex CLI"              "not on PATH"
fi

[[ -f "$CODEX_SKILL_DIR/SKILL.md" ]] \
  && report PASS "SKILL.md"            "$CODEX_SKILL_DIR/SKILL.md" \
  || report FAIL "SKILL.md"            "missing — run codex/setup.sh"

if [[ -f "$CODEX_SKILL_DIR/planning-preferences.md" ]]; then
  if grep -q "<REPLACE_WITH\|<your-\|<Calendar Label" "$CODEX_SKILL_DIR/planning-preferences.md"; then
    report FAIL "planning-preferences.md" "still contains placeholders"
  else
    report PASS "planning-preferences.md" "exists, no placeholders left"
  fi
else
  report FAIL "planning-preferences.md" "missing — copy from examples/"
fi

[[ -f "$CODEX_SKILL_DIR/agents/openai.yaml" ]] \
  && report PASS "agents/openai.yaml"  "ok" \
  || report FAIL "agents/openai.yaml"  "missing"

if [[ -f "$CODEX_AUTO_DIR/automation.toml" ]]; then
  if grep -q "{{" "$CODEX_AUTO_DIR/automation.toml"; then
    report FAIL "automation.toml"      "unresolved {{PLACEHOLDERS}} — re-run setup.sh"
  else
    report PASS "automation.toml"      "ok"
  fi
else
  report FAIL "automation.toml"        "missing — run codex/setup.sh"
fi

[[ -f "$CODEX_AUTO_DIR/memory.md" ]] \
  && report PASS "memory.md"           "$(wc -l <"$CODEX_AUTO_DIR/memory.md" | tr -d ' ') lines" \
  || report SKIP "memory.md"           "will be created on first run"

# Check MCP enablement (informational)
if [[ -f "$CODEX_CONFIG" ]]; then
  for mcp in notion google-calendar gmail; do
    if grep -A2 "\[mcp_servers.${mcp}\]" "$CODEX_CONFIG" 2>/dev/null | grep -q "enabled = true"; then
      report PASS "mcp.${mcp}"          "enabled in ~/.codex/config.toml"
    else
      report SKIP "mcp.${mcp}"          "not enabled (set enabled = true in ~/.codex/config.toml)"
    fi
  done
else
  report SKIP "codex config.toml"      "missing — run codex once to bootstrap"
fi

echo
[[ $failed -eq 0 ]] && echo "all checks pass." && exit 0
echo "one or more checks failed." && exit 1
