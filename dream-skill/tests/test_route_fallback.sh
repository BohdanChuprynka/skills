#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work" "$TMP/vault/wiki"
cat > "$TMP/vault/wiki/project.md" <<'MD'
---
updated: 2026-07-12
---
# Project

## Current Goals
MD
cat > "$TMP/config.toml" <<EOF
[vaults.projects]
root = "$TMP/vault"
description = "Named project facts"
EOF
cat > "$TMP/work/route-batches.json" <<'JSON'
[
  {
    "batch_id":"route-0001",
    "page_catalog":[{"page_id":"p001","vault":"projects","page":"wiki/project.md","title":"Project","headings":["Current Goals"]}],
    "candidates":[{"candidate_id":"c-gap","candidate":{"content":"The project has a durable goal.","confidence":"high","source_chat":"chat","source_date":"2026-07-12","source_role":"user","source_event":1,"evidence":"durable goal","memory_tier":"current"},"allowed_page_ids":["p001"]}]
  }
]
JSON
cat > "$TMP/fake-codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
prompt=$(cat)
input=$(printf '%s\n' "$prompt" | awk -F': ' '/^input_path:/ {print $2}')
jq '[. as $batch | .candidates[] | . as $candidate | ($candidate.allowed_page_ids[0]) as $pid | ($batch.page_catalog[] | select(.page_id==$pid)) as $page | {candidate_id:$candidate.candidate_id,status:"routed",vault:$page.vault,page:$page.page,section:"Current Goals",routing_confidence:"medium"}]' "$input" > "$out"
SH
chmod +x "$TMP/fake-codex"

python3 - "$SKILL_DIR" "$TMP" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace

skill = Path(sys.argv[1])
tmp = Path(sys.argv[2])
sys.path.insert(0, str(skill / "scripts"))
spec = importlib.util.spec_from_file_location("dream_run", skill / "scripts/dream-run.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)

candidate = json.loads((tmp / "work/route-batches.json").read_text())[0]["candidates"][0]["candidate"]
records = [{"candidate_id":"c-gap","candidate":candidate,"route":{"status":"gap","vault":None,"page":None,"section":None,"routing_confidence":"low"}}]
args = SimpleNamespace(
    route_gap_retry=True,
    cwd=tmp,
    engine="codex",
    codex_bin=str(tmp / "fake-codex"),
    claude_bin="claude",
    route_concurrency=1,
    route_timeout=30,
    agent_retries=0,
    config=tmp / "config.toml",
    route_model="gpt-5.6-luna",
    route_fallback_effort="medium",
)
merged, stats = module.run_route_fallback(args, tmp / "work", records)
assert stats == {"attempted": 1, "recovered": 1, "remaining": 0}, stats
assert merged[0]["route"]["status"] == "routed", merged
assert merged[0]["route_attempts"] == 2
assert merged[0]["initial_route_status"] == "gap"
assert (tmp / "work/route-fallback/route-attempt-ledger.jsonl").is_file()

args.route_gap_retry = False
unchanged, disabled = module.run_route_fallback(args, tmp / "work", records)
assert unchanged == records
assert disabled == {"attempted": 0, "recovered": 0, "remaining": 1}
PY

echo "test_route_fallback: ok"
