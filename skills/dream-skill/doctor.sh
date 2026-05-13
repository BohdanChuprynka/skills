#!/usr/bin/env bash
# doctor.sh — non-interactive health check for dream-skill.
#
# Exits 0 if every check is PASS or SKIP. Exits 1 on any FAIL.
# Each check prints one line:
#   [PASS|FAIL|SKIP] <check-name> — <detail>

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SKILL_DIR/config"

# PATH boost (cron-friendly)
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

VAULT_ROOT="${DREAM_VAULT_ROOT:-$HOME/Documents/Obsidian}"
OUTPUT_DIR="${DREAM_OUTPUT_DIR:-$VAULT_ROOT/dream-reports}"
SESSIONS_ROOT="${DREAM_SESSIONS_ROOT:-$HOME/.claude/projects}"
MCP_CONFIG="${DREAM_MCP_CONFIG:-$CONFIG_DIR/mcp-config.json}"
VAULT_TOML="$CONFIG_DIR/vault-paths.toml"

FAILS=0
PASSES=0
SKIPS=0

pass() { printf "[PASS] %-35s — %s\n" "$1" "$2"; PASSES=$((PASSES + 1)); }
fail() { printf "[FAIL] %-35s — %s\n" "$1" "$2"; FAILS=$((FAILS + 1)); }
sskip(){ printf "[SKIP] %-35s — %s\n" "$1" "$2"; SKIPS=$((SKIPS + 1)); }

echo "dream-skill doctor.sh — $(date -u +%FT%TZ)"
echo "---------------------------------------------------------------"

# ============================================================
# 1. Python 3.11+
# ============================================================
if command -v python3 >/dev/null 2>&1; then
  PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")"
  PY_MAJOR="${PY_VER%%.*}"
  PY_MINOR="${PY_VER##*.}"
  if [[ "$PY_MAJOR" -ge 3 ]] && [[ "$PY_MINOR" -ge 11 ]]; then
    pass "python3 >= 3.11" "$PY_VER at $(command -v python3)"
  else
    fail "python3 >= 3.11" "found $PY_VER (need >= 3.11 for tomllib)"
  fi
else
  fail "python3 >= 3.11" "python3 not on PATH"
fi

# ============================================================
# 2. claude CLI on PATH
# ============================================================
if command -v claude >/dev/null 2>&1; then
  pass "claude CLI" "$(command -v claude)"
else
  fail "claude CLI" "not on PATH; install via https://docs.claude.com/claude-code"
fi

# ============================================================
# 3. Vault root exists
# ============================================================
if [[ -d "$VAULT_ROOT" ]]; then
  pass "vault root exists" "$VAULT_ROOT"
else
  fail "vault root exists" "not a directory: $VAULT_ROOT"
fi

# ============================================================
# 4. vault-paths.toml parses
# ============================================================
if [[ -f "$VAULT_TOML" ]]; then
  if python3 - "$VAULT_TOML" <<'PYEOF' 2>/dev/null
import sys, tomllib, pathlib
p = pathlib.Path(sys.argv[1])
tomllib.loads(p.read_text())
PYEOF
  then
    pass "vault-paths.toml parses" "$VAULT_TOML"
  else
    fail "vault-paths.toml parses" "TOML decode error at $VAULT_TOML"
  fi
else
  sskip "vault-paths.toml parses" "no config file (will fall back to scanning all .md)"
fi

# ============================================================
# 5. Each configured vault subdir exists
# ============================================================
if [[ -f "$VAULT_TOML" ]] && [[ -d "$VAULT_ROOT" ]]; then
  MISSING="$(python3 - "$VAULT_TOML" "$VAULT_ROOT" <<'PYEOF' 2>/dev/null
import sys, tomllib, pathlib
toml_path = pathlib.Path(sys.argv[1])
vault_root = pathlib.Path(sys.argv[2])
cfg = tomllib.loads(toml_path.read_text())
vaults = cfg.get("vaults", [])
missing = [v for v in vaults if not (vault_root / v).is_dir()]
print(",".join(missing))
PYEOF
)"
  if [[ -z "$MISSING" ]]; then
    pass "vault subdirs exist" "all configured subdirs present"
  else
    fail "vault subdirs exist" "missing: $MISSING"
  fi
else
  sskip "vault subdirs exist" "no config or vault root to check"
fi

# ============================================================
# 6. Output dir writable
# ============================================================
mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
if [[ -d "$OUTPUT_DIR" ]] && [[ -w "$OUTPUT_DIR" ]]; then
  pass "output dir writable" "$OUTPUT_DIR"
else
  fail "output dir writable" "$OUTPUT_DIR is not a writable directory"
fi

# ============================================================
# 7. Sessions root has JSONL files
# ============================================================
if [[ -d "$SESSIONS_ROOT" ]]; then
  JSONL_COUNT="$(find "$SESSIONS_ROOT" -name '*.jsonl' -type f 2>/dev/null | head -1 | wc -l | tr -d ' ')"
  if [[ "$JSONL_COUNT" -gt 0 ]]; then
    pass "sessions root has data" "$SESSIONS_ROOT"
  else
    fail "sessions root has data" "no .jsonl files found under $SESSIONS_ROOT"
  fi
else
  fail "sessions root has data" "directory not found: $SESSIONS_ROOT"
fi

# ============================================================
# 8. mcp-config.json parses (if present)
# ============================================================
if [[ -f "$MCP_CONFIG" ]]; then
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MCP_CONFIG" 2>/dev/null; then
    pass "mcp-config.json parses" "$MCP_CONFIG"
  else
    fail "mcp-config.json parses" "invalid JSON at $MCP_CONFIG"
  fi

  # ============================================================
  # 9. Each declared MCP package responds to --version (timeout 10s)
  # ============================================================
  if command -v npx >/dev/null 2>&1; then
    PACKAGES="$(python3 - "$MCP_CONFIG" <<'PYEOF' 2>/dev/null
import json, sys
cfg = json.load(open(sys.argv[1]))
servers = cfg.get("mcpServers", {})
out = []
for name, spec in servers.items():
    args = spec.get("args", [])
    # find first non-flag arg = package name
    pkg = next((a for a in args if not a.startswith("-")), None)
    if pkg:
        out.append(f"{name}\t{pkg}")
print("\n".join(out))
PYEOF
)"
    if [[ -z "$PACKAGES" ]]; then
      sskip "mcp packages reachable" "no servers declared"
    else
      while IFS=$'\t' read -r name pkg; do
        [[ -z "$name" ]] && continue
        if timeout 10 npx -y "$pkg" --version >/dev/null 2>&1; then
          pass "mcp pkg: $name" "$pkg"
        else
          fail "mcp pkg: $name" "$pkg did not respond in 10s (may need first-run install)"
        fi
      done <<< "$PACKAGES"
    fi
  else
    sskip "mcp packages reachable" "npx not on PATH"
  fi
else
  sskip "mcp-config.json parses" "no config (run setup.sh to add)"
  sskip "mcp packages reachable" "no config"
fi

# ============================================================
# 10. Disk space — output dir has > 100 MB free
# ============================================================
if [[ -d "$OUTPUT_DIR" ]]; then
  # df -k → 1K-blocks; available is column 4 on most platforms
  FREE_KB="$(df -k "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$FREE_KB" ]] && [[ "$FREE_KB" -gt 102400 ]]; then
    pass "disk space (>100 MB)" "$((FREE_KB / 1024)) MB free on $OUTPUT_DIR"
  else
    fail "disk space (>100 MB)" "only ${FREE_KB:-?} KB free on $OUTPUT_DIR"
  fi
else
  sskip "disk space (>100 MB)" "output dir does not exist"
fi

# ============================================================
# Summary
# ============================================================
echo "---------------------------------------------------------------"
printf "passed: %d  failed: %d  skipped: %d\n" "$PASSES" "$FAILS" "$SKIPS"

if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
