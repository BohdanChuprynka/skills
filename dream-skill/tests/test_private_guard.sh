#!/usr/bin/env bash
# Guard: user-facing docs (SKILL.md, README) must reference the opt-out only as
# PROSE (`/dream-skill --ignore`), never reproduce the serialized
# `<command-args>…--ignore` form. That serialized text rides into transcripts (via
# the skill catalog, or a Read of these files); if a doc reproduced it, the jq-less
# fallback path could mistake it for a real invocation and mark unrelated chats
# private. Also assert the feature IS documented and advertised in the description.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
fail() { echo "FAIL: $*"; exit 1; }

if [ -f "$ROOT/skills/dream-skill/SKILL.md" ]; then
  SKILL="$ROOT/skills/dream-skill/SKILL.md"
  DOCS=("$SKILL" "$ROOT/README.md")
else
  SKILL="$ROOT/SKILL.md"
  DOCS=("$SKILL")
fi

# 1. No serialized command form in user-facing docs (the self-trigger invariant).
for f in "${DOCS[@]}"; do
  [ -f "$f" ] || fail "missing $f"
  grep -qE '<command-args>[^<]*--ignore' "$f" \
    && fail "$f contains serialized <command-args>…--ignore (self-trigger risk); use prose '/dream-skill --ignore'"
done
echo "PASS: docs contain no serialized <command-args>…--ignore form"

# 2. Feature documented in SKILL.md and, in the source checkout, README.
grep -q -- '--ignore'   "$SKILL"  || fail "SKILL.md does not document --ignore"
grep -q -- '--unignore' "$SKILL"  || fail "SKILL.md does not document --unignore"
if [ "${#DOCS[@]}" -gt 1 ]; then
  grep -q -- '--ignore' "${DOCS[1]}" || fail "README does not document --ignore"
fi
echo "PASS: --ignore/--unignore documented in SKILL.md and README"

# 3. description: frontmatter advertises the opt-out (zero-config discoverability —
#    this line is how Claude learns the command exists, every session).
awk '/^description:/{print; exit}' "$SKILL" | grep -q -- '--ignore' \
  || fail "SKILL.md description: frontmatter does not mention --ignore (discoverability)"
echo "PASS: SKILL.md description advertises the opt-out"

echo
echo "All private-guard tests passed."
