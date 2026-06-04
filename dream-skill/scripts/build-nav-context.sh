#!/usr/bin/env bash
# build-nav-context.sh  — Assemble a bounded routing-context block for the
# dream-skill router LLM prompt.
#
# Usage:
#   build-nav-context.sh [--config <path-to-config.toml>]
#
# Config: TOML format (same as ~/.claude/dream-skill/config.toml).
#   Vault names from ^\[vaults\.<name>\] headers; root = and description = per block.
#   Default: ${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}
#   Override with --config for hermetic tests (pass a TOML fixture).
#
# Stdout: a single NAV-CONTEXT block (≤ 7 800 chars).
# Stderr: warnings for missing vault roots or missing wiki/index.md; never fatal.
set -euo pipefail

CONFIG="${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse TOML: extract vault names, roots, and descriptions.
# Mirrors the approach in scripts/report.sh.
# Strategy: scan line-by-line; when we hit [vaults.<name>], capture the name;
# within that block, capture root = "..." and description = "..." until next [.
# ---------------------------------------------------------------------------
parse_vaults() {
  local cfg="$1"
  local current_name="" current_root="" current_desc=""
  local in_vault=0

  emit_vault() {
    if [[ -n "$current_name" && -n "$current_root" ]]; then
      printf '%s\t%s\t%s\n' "$current_name" "$current_root" "${current_desc:-unknown}"
    fi
    current_name=""; current_root=""; current_desc=""; in_vault=0
  }

  while IFS= read -r line; do
    # New [vaults.<name>] section
    if [[ "$line" =~ ^\[vaults\.([A-Za-z0-9_-]+)\] ]]; then
      emit_vault
      current_name="${BASH_REMATCH[1]}"
      in_vault=1
      continue
    fi
    # Any other [section] ends the current vault block
    if [[ "$line" =~ ^\[ ]]; then
      emit_vault
      continue
    fi
    if [[ $in_vault -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]*root[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
        current_root="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ ^[[:space:]]*description[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
        current_desc="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$cfg"
  emit_vault  # flush last block
}

# Hard ceiling: truncate total output at 7800 chars (leaves headroom for delimiters)
MAX_CHARS=7800
ACCUMULATED=""

append() {
  local chunk="$1"
  local remaining=$(( MAX_CHARS - ${#ACCUMULATED} ))
  if [[ $remaining -le 0 ]]; then return; fi
  if [[ ${#chunk} -gt $remaining ]]; then
    ACCUMULATED+="${chunk:0:$remaining}"
    ACCUMULATED+="... [truncated]"
  else
    ACCUMULATED+="$chunk"
  fi
}

append "=== NAV-CONTEXT BEGIN ===\n"
append "# Vault Routing Context\n"
append "# Generated: $(date -u +%Y-%m-%dT%H:%MZ)\n\n"

while IFS=$'\t' read -r vault_name vault_root vault_desc; do
  if [[ ! -d "$vault_root" ]]; then
    echo "WARN: vault '$vault_name' root not found: $vault_root — skipping" >&2
    continue
  fi

  append "## vault: $vault_name\n"
  append "path: $vault_root\n"
  append "purpose: $vault_desc\n"

  # Index: up to 40 lines from wiki/index.md
  local_index="$vault_root/wiki/index.md"
  if [[ -f "$local_index" ]]; then
    append "index (first 40 lines):\n"
    while IFS= read -r line; do
      append "  $line\n"
    done < <(head -40 "$local_index")
  else
    echo "WARN: vault '$vault_name' has no wiki/index.md — skipping index" >&2
    append "index: (no wiki/index.md found)\n"
  fi

  # Dir scan: markdown files in wiki/ (maxdepth 1), up to 20 entries
  append "pages on disk:\n"
  while IFS= read -r fpath; do
    fname=$(basename "$fpath")
    append "  $fname\n"
  done < <(find "$vault_root/wiki" -maxdepth 1 -name "*.md" ! -name "index.md" ! -name "log.md" 2>/dev/null | sort | head -20)

  append "\n"
done < <(parse_vaults "$CONFIG")

append "=== NAV-CONTEXT END ===\n"

FINAL="${ACCUMULATED//\\n/
}"
printf '%s' "$FINAL"
