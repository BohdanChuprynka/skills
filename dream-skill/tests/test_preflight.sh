#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if "$SKILL_DIR/scripts/dream-run.py" --shadow --config "$TMP/missing.toml" \
  --home "$TMP/state" > "$TMP/out" 2> "$TMP/err"; then
  echo "missing config unexpectedly passed preflight" >&2
  exit 1
fi
rg -q 'preflight failed: config not found' "$TMP/err"
[ ! -e "$TMP/state" ]

echo "test_preflight: ok"
