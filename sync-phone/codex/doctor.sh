#!/usr/bin/env bash
#
# doctor.sh — health check for the Codex install of sync-phone.

set -uo pipefail

CODEX_SKILL_DIR="$HOME/.codex/skills/sync-phone"
CODEX_AUTO_DIR="$HOME/.codex/automations/sync-phone"
SETTINGS="$CODEX_SKILL_DIR/config/settings.conf"
failed=0
report() { printf '[%-4s] %-28s — %s\n' "$1" "$2" "$3"; [[ "$1" == "FAIL" ]] && failed=1 || true; }

if command -v codex >/dev/null 2>&1; then
  report PASS "codex CLI"           "$(codex --version 2>&1 | head -1)"
else
  report FAIL "codex CLI"           "not on PATH"
fi

[[ -f "$CODEX_SKILL_DIR/SKILL.md" ]] \
  && report PASS "SKILL.md"         "$CODEX_SKILL_DIR/SKILL.md" \
  || report FAIL "SKILL.md"         "missing — run setup.sh"

[[ -f "$CODEX_SKILL_DIR/agents/openai.yaml" ]] \
  && report PASS "agents/openai.yaml" "ok" \
  || report FAIL "agents/openai.yaml" "missing — run setup.sh"

if [[ -f "$SETTINGS" ]]; then
  # shellcheck disable=SC1090
  source "$SETTINGS"
  CAP="${CAPTURE_DIR/#\~/$HOME}"
  VLT="${VAULTS_DIR/#\~/$HOME}"
  [[ -d "$CAP" ]] \
    && report PASS "CAPTURE_DIR"    "$CAP" \
    || report FAIL "CAPTURE_DIR"    "$CAP does not exist"
  [[ -f "$CAP/iphone-raw.md" ]] \
    && report PASS "iphone-raw.md"  "exists ($(wc -c <"$CAP/iphone-raw.md" | tr -d ' ') bytes)" \
    || report FAIL "iphone-raw.md"  "missing in $CAP"
  [[ -d "$VLT" ]] \
    && report PASS "VAULTS_DIR"     "$VLT ($(find "$VLT" -maxdepth 2 \( -name CLAUDE.md -o -name AGENTS.md \) 2>/dev/null | wc -l | tr -d ' ') vault marker files found)" \
    || report FAIL "VAULTS_DIR"     "$VLT does not exist"
else
  report FAIL "settings.conf"       "missing — run setup.sh"
fi

if [[ -f "$CODEX_AUTO_DIR/automation.toml" ]]; then
  if grep -q "{{" "$CODEX_AUTO_DIR/automation.toml"; then
    report FAIL "automation.toml"   "unresolved {{placeholders}} — re-run setup.sh"
  else
    report PASS "automation.toml"   "present (optional cron — check status field)"
  fi
else
  report SKIP "automation.toml"     "not installed (optional; on-demand runs work)"
fi

echo
[[ $failed -eq 0 ]] && echo "all checks pass." && exit 0
echo "one or more checks failed." && exit 1
