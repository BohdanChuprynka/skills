#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/Now.md" <<'MD'
## As of 2026-07-03

## This week (W6: 6/29 – 7/5)
- Fri 7/3 (today): follow up

## Hard dates ahead
- 2026-07-15: contract target
MD

if python3 "$SKILL_DIR/scripts/current_page_lint.py" "$TMP/Now.md" --today 2026-07-28 --strict > "$TMP/findings.json"; then
  echo "expected strict current-page lint to fail" >&2
  exit 1
fi
jq -e '.findings | any(.signal == "stale_as_of")' "$TMP/findings.json" >/dev/null
jq -e '.findings | any(.signal == "expired_weekly_section")' "$TMP/findings.json" >/dev/null
jq -e '.findings | any(.signal == "past_current_event")' "$TMP/findings.json" >/dev/null

echo "test_current_page_lint: ok"
