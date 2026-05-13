#!/usr/bin/env bash
# apply_undo.sh — reverse dream-skill applied edits from a rollback log.
#
# Usage:
#   apply_undo.sh <YYYY-MM-DD>                  revert every edit applied that cycle
#   apply_undo.sh <YYYY-MM-DD> --only N         revert just the Nth applied entry (0-indexed)
#   apply_undo.sh <YYYY-MM-DD> --list           list applied entries without reverting
#   apply_undo.sh <YYYY-MM-DD> --yes            skip confirmation prompt
#
# Optional flags:
#   --vault-root PATH        override vault root
#   --rollback-dir PATH      override rollback dir (default: <vault-root>/.dream-rollback)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_ROOT="${DREAM_VAULT_ROOT:-$HOME/Documents/Obsidian}"
ROLLBACK_DIR=""
MODE="all"
ONLY_INDEX=""
YES=0

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <YYYY-MM-DD> [--only N | --list] [--yes] [--vault-root PATH] [--rollback-dir PATH]" >&2
  exit 1
fi

DATE="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)         MODE="only"; ONLY_INDEX="$2"; shift 2 ;;
    --list)         MODE="list"; shift ;;
    --yes|-y)       YES=1; shift ;;
    --vault-root)   VAULT_ROOT="$2"; shift 2 ;;
    --rollback-dir) ROLLBACK_DIR="$2"; shift 2 ;;
    *) echo "apply_undo.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Expand ~
VAULT_ROOT="${VAULT_ROOT/#\~/$HOME}"
if [[ -z "$ROLLBACK_DIR" ]]; then
  ROLLBACK_DIR="$VAULT_ROOT/.dream-rollback"
else
  ROLLBACK_DIR="${ROLLBACK_DIR/#\~/$HOME}"
fi

ROLLBACK="$ROLLBACK_DIR/rollback-$DATE.json"

if [[ ! -s "$ROLLBACK" ]]; then
  echo "apply_undo.sh: rollback log not found or empty: $ROLLBACK" >&2
  exit 1
fi

# ============================================================
# List mode — short-circuit without confirmation
# ============================================================
if [[ "$MODE" == "list" ]]; then
  ROLLBACK="$ROLLBACK" DATE="$DATE" python3 <<'PYEOF'
import json, os, sys
from pathlib import Path
data = json.loads(Path(os.environ["ROLLBACK"]).read_text())
applied = data.get("applied", [])
print(f"applied entries in cycle {os.environ['DATE']} ({len(applied)} total):")
for i, e in enumerate(applied):
    title = (e.get("title") or "")[:70]
    print(f"  [{i}] {e.get('file')}: {title}")
PYEOF
  exit 0
fi

# ============================================================
# Preview + confirmation
# ============================================================
echo "about to revert from rollback log: $ROLLBACK"
echo ""
ROLLBACK="$ROLLBACK" MODE="$MODE" ONLY_INDEX="$ONLY_INDEX" python3 <<'PYEOF'
import json, os, sys
from pathlib import Path
data = json.loads(Path(os.environ["ROLLBACK"]).read_text())
applied = data.get("applied", [])
mode = os.environ["MODE"]
only_idx = os.environ.get("ONLY_INDEX", "")
if mode == "only":
    try:
        i = int(only_idx)
        entries = [(i, applied[i])]
    except (ValueError, IndexError):
        print(f"error: invalid index {only_idx!r}", file=sys.stderr); sys.exit(1)
else:
    entries = list(enumerate(applied))
print(f"the following {len(entries)} file(s) will be reverted:")
for i, e in entries:
    print(f"  [{i}] {e.get('file')}  ({(e.get('title') or '')[:60]})")
PYEOF

if [[ "$YES" != "1" ]]; then
  printf "\nproceed? [y/N]: "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "aborted."; exit 0 ;;
  esac
fi

# ============================================================
# Apply revert
# ============================================================
ROLLBACK="$ROLLBACK" VAULT_ROOT="$VAULT_ROOT" MODE="$MODE" ONLY_INDEX="$ONLY_INDEX" \
SKILL_DIR="$SKILL_DIR" DATE="$DATE" python3 <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path

rollback_path = Path(os.environ["ROLLBACK"])
vault_root = Path(os.environ["VAULT_ROOT"])
mode = os.environ["MODE"]
only_index = os.environ.get("ONLY_INDEX", "")
skill_dir = Path(os.environ["SKILL_DIR"])
cycle_date = os.environ["DATE"]

data = json.loads(rollback_path.read_text())
applied = data.get("applied", [])

if not applied:
    print(f"no applied entries in {rollback_path}")
    sys.exit(0)

targets = []
if mode == "only":
    try:
        idx = int(only_index)
        targets = [(idx, applied[idx])]
    except (ValueError, IndexError):
        print(f"error: invalid index {only_index!r} (have {len(applied)} entries)", file=sys.stderr)
        sys.exit(1)
else:
    targets = list(enumerate(applied))

reverted = 0
errors = 0
for idx, entry in targets:
    file_rel = entry.get("file")
    old_content = entry.get("old_content")
    if not file_rel or old_content is None:
        print(f"  [skip] [{idx}] missing file or old_content")
        errors += 1
        continue
    target = vault_root / file_rel
    if not target.exists():
        print(f"  [skip] [{idx}] target does not exist: {target}")
        errors += 1
        continue
    current = target.read_text(encoding="utf-8")
    expected_new = entry.get("new_content", "")
    if expected_new and current.strip() != expected_new.strip():
        print(f"  [skip] [{idx}] {file_rel} content changed since apply -- refusing to revert. Inspect manually.")
        errors += 1
        continue
    target.write_text(old_content, encoding="utf-8")
    print(f"  [ok]   [{idx}] reverted: {file_rel}")
    reverted += 1

apply_log = skill_dir / ".apply-log.jsonl"
apply_log.parent.mkdir(parents=True, exist_ok=True)
with apply_log.open("a", encoding="utf-8") as f:
    f.write(json.dumps({
        "ts": datetime.now(timezone.utc).isoformat(),
        "cycle_date": cycle_date,
        "action": "undo",
        "mode": mode,
        "only_index": only_index if mode == "only" else None,
        "reverted": reverted,
        "errors": errors,
    }) + "\n")

print(f"\n  reverted: {reverted}  errors: {errors}")
sys.exit(0 if errors == 0 else 2)
PYEOF
