#!/usr/bin/env bash
#
# doctor.sh — non-interactive health check for the Claude target.
#
# Exit 0 if every check is PASS or SKIP. Exit 1 on any FAIL.
# Each check prints one line: [PASS|FAIL|SKIP] <name> — <detail>

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
PROMPTS_DIR="$(cd "$SKILL_DIR/../../prompts" 2>/dev/null && pwd || echo "")"

failed=0
report() {  # $1 status, $2 name, $3 detail
  printf '[%-4s] %-32s — %s\n' "$1" "$2" "$3"
  [[ "$1" == "FAIL" ]] && failed=1 || true
}

# 1. claude CLI
if command -v claude >/dev/null 2>&1; then
  report PASS "claude CLI"           "$(claude --version 2>&1 | head -1)"
else
  report FAIL "claude CLI"           "not on PATH"
fi

# 2. npx
if command -v npx >/dev/null 2>&1; then
  report PASS "npx"                  "$(npx --version)"
else
  report FAIL "npx"                  "not on PATH (Node.js missing)"
fi

# 3. python3
if command -v python3 >/dev/null 2>&1; then
  report PASS "python3"              "$(python3 --version)"
else
  report FAIL "python3"              "not on PATH"
fi

# 4. settings.conf
if [[ -f "$CONFIG_DIR/settings.conf" ]]; then
  perms=$(stat -f '%Lp' "$CONFIG_DIR/settings.conf" 2>/dev/null || stat -c '%a' "$CONFIG_DIR/settings.conf")
  if [[ "$perms" == "600" ]]; then
    report PASS "settings.conf"      "perms $perms"
  else
    report FAIL "settings.conf"      "perms $perms (expected 600) — run: chmod 600 $CONFIG_DIR/settings.conf"
  fi
else
  report FAIL "settings.conf"        "missing — run setup.sh"
fi

# 5. planning-preferences.md
if [[ -f "$CONFIG_DIR/planning-preferences.md" ]]; then
  if grep -q "<REPLACE_WITH" "$CONFIG_DIR/planning-preferences.md" 2>/dev/null; then
    report FAIL "planning-preferences.md" "still contains <REPLACE_WITH...> placeholders"
  else
    report PASS "planning-preferences.md" "exists, no placeholders left"
  fi
else
  report FAIL "planning-preferences.md" "missing — run setup.sh"
fi

# 6. mcp-config.json
if [[ -f "$CONFIG_DIR/mcp-config.json" ]]; then
  perms=$(stat -f '%Lp' "$CONFIG_DIR/mcp-config.json" 2>/dev/null || stat -c '%a' "$CONFIG_DIR/mcp-config.json")
  if [[ "$perms" != "600" ]]; then
    report FAIL "mcp-config.json"    "perms $perms (expected 600) — chmod 600 it"
  elif grep -q "<REPLACE_WITH" "$CONFIG_DIR/mcp-config.json" 2>/dev/null; then
    report FAIL "mcp-config.json"    "still contains <REPLACE_WITH...> placeholders"
  else
    report PASS "mcp-config.json"    "perms 600, no placeholders"
  fi
else
  report FAIL "mcp-config.json"      "missing — run setup.sh"
fi

# 7. JSON validity
if [[ -f "$CONFIG_DIR/mcp-config.json" ]]; then
  if python3 -c "import json,sys; json.load(open('$CONFIG_DIR/mcp-config.json'))" 2>/dev/null; then
    report PASS "mcp-config json"    "parses"
  else
    report FAIL "mcp-config json"    "INVALID JSON — fix syntax"
  fi
fi

# 8. CALENDAR_CONTEXT path
if [[ -f "$CONFIG_DIR/settings.conf" ]]; then
  CC=$(grep '^CALENDAR_CONTEXT=' "$CONFIG_DIR/settings.conf" | head -1 | cut -d= -f2- | tr -d '"')
  if [[ -z "$CC" ]]; then
    report SKIP "CALENDAR_CONTEXT"   "not set (optional, but the planner relies on it)"
  elif [[ -f "$CC" ]]; then
    report PASS "CALENDAR_CONTEXT"   "$CC"
  else
    report FAIL "CALENDAR_CONTEXT"   "$CC does not exist"
  fi
fi

# 9. prompt template
if [[ -n "$PROMPTS_DIR" && -f "$PROMPTS_DIR/cron-prompt.md" ]]; then
  report PASS "cron-prompt.md"       "$PROMPTS_DIR/cron-prompt.md"
else
  report FAIL "cron-prompt.md"       "missing — re-clone repo"
fi

# 10. memory.md
if [[ -f "$SKILL_DIR/memory/memory.md" ]]; then
  report PASS "memory.md"            "$(wc -l <"$SKILL_DIR/memory/memory.md" | tr -d ' ') lines"
else
  report SKIP "memory.md"            "missing — will be auto-seeded on first run"
fi

# 11. launchd job (informational only)
PLIST="$HOME/Library/LaunchAgents/com.user.calendar-plan.plist"
if [[ -f "$PLIST" ]]; then
  if launchctl list 2>/dev/null | grep -q "com.user.calendar-plan"; then
    report PASS "launchd job"        "loaded as com.user.calendar-plan"
  else
    report FAIL "launchd job"        "plist present but not loaded — run: launchctl load $PLIST"
  fi
else
  report SKIP "launchd job"          "no plist installed (manual runs only)"
fi

echo
if [[ $failed -eq 0 ]]; then
  echo "all checks pass."
  exit 0
else
  echo "one or more checks failed."
  exit 1
fi
