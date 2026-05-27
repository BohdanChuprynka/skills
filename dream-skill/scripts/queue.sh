#!/usr/bin/env bash
# dream-skill queue manager.
# Stores deferred-decision facts for manual review.
# Three buckets: destructive, uncertain, brainstormed.
# Queue file: $DREAM_QUEUE_FILE (default ~/.claude/dream-skill/queue/pending.md)
#
# Usage:
#   queue.sh append --bucket <destructive|uncertain|brainstormed> \
#     --title <t> --evidence <e> --confidence <c> --target <t>
#   queue.sh list

set -euo pipefail

QUEUE_FILE="${DREAM_QUEUE_FILE:-$HOME/.claude/dream-skill/queue/pending.md}"

die() { echo "queue: $*" >&2; exit 1; }

ensure_queue_file() {
  mkdir -p "$(dirname "$QUEUE_FILE")"
  [ -f "$QUEUE_FILE" ] || touch "$QUEUE_FILE"
}

bucket_header() {
  case "$1" in
    destructive)  echo "## Destructive edits" ;;
    uncertain)    echo "## Uncertain facts" ;;
    brainstormed) echo "## Brainstormed ideas" ;;
    *) die "unknown bucket: $1" ;;
  esac
}

cmd_append() {
  local bucket="" title="" evidence="" confidence="" target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bucket) bucket="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --evidence) evidence="$2"; shift 2 ;;
      --confidence) confidence="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done

  [ -n "$bucket" ]     || die "missing --bucket"
  [ -n "$title" ]      || die "missing --title"
  [ -n "$evidence" ]   || die "missing --evidence"
  [ -n "$confidence" ] || die "missing --confidence"
  [ -n "$target" ]     || die "missing --target"

  local header
  header=$(bucket_header "$bucket")  # validates bucket name

  ensure_queue_file

  # Ensure the section header exists
  if ! grep -Fxq -- "$header" "$QUEUE_FILE"; then
    {
      echo ""
      echo "$header"
      echo ""
    } >> "$QUEUE_FILE"
  fi

  # Append entry under the section header
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build the entry in a temp file (awk -v can't carry newlines)
  local entry_file
  entry_file=$(mktemp)
  cat > "$entry_file" <<EOF

### $title

**Bucket:** $bucket
**Confidence:** $confidence
**Target:** $target
**Captured:** $ts

**Evidence:**

> $evidence

---
EOF

  # Insert entry after the section header (before the next ## or EOF)
  awk -v header="$header" -v entry_file="$entry_file" '
    BEGIN {
      inserted = 0
      in_section = 0
      entry = ""
      while ((getline line < entry_file) > 0) {
        entry = entry (entry == "" ? "" : "\n") line
      }
      close(entry_file)
    }
    {
      if ($0 == header) { print; in_section = 1; next }
      if (in_section && !inserted && /^## /) {
        print entry
        inserted = 1
        in_section = 0
      }
      print
    }
    END {
      if (in_section && !inserted) {
        print entry
      }
    }
  ' "$QUEUE_FILE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"

  rm -f "$entry_file"
}

cmd_list() {
  ensure_queue_file
  if [ ! -s "$QUEUE_FILE" ]; then
    echo "(queue is empty)"
    return 0
  fi
  cat "$QUEUE_FILE"
}

# --- dispatch -----------------------------------------------------------
[ $# -ge 1 ] || die "usage: queue.sh <append|list> [args]"

SUBCMD="$1"; shift
case "$SUBCMD" in
  append) cmd_append "$@" ;;
  list)   cmd_list "$@" ;;
  *) die "unknown subcommand: $SUBCMD" ;;
esac
