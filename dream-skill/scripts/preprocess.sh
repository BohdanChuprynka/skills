#!/usr/bin/env bash
# dream-skill transcript preprocessor.
# Reads a Claude Code transcript JSONL file; emits cleaned plain-text
# on stdout. Keeps user + assistant text content only.
#
# Handles two JSONL shapes:
#   1. Real Claude Code:  {"type":"user|assistant","message":{"role":..,"content":..},"isMeta":bool}
#   2. Simple flat:       {"role":"user|assistant","content":..}
#
# Drops: type=attachment|permission-mode|ai-title|mode|system|last-prompt,
#        isMeta=true lines, thinking blocks, tool_use, tool_result,
#        image, system-reminder tags, local-command-caveat tags.

set -euo pipefail

TRANSCRIPT="${1:?usage: preprocess.sh <transcript.jsonl>}"
[ -f "$TRANSCRIPT" ] || { echo "no such file: $TRANSCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

jq -r '
  # Determine shape: nested ".message" or flat top-level
  (if .message then .message else . end) as $m
  | (.type // $m.role // "unknown") as $entry_type

  # Filter to user/assistant only; drop meta lines
  | select(($entry_type == "user" or $entry_type == "assistant")
           and (.isMeta // false) != true)

  # Extract role from message (nested) or top-level (flat)
  | ($m.role // .role // "unknown") as $role

  # Extract text content
  | ($m.content // .content) as $content
  | (
      if $content | type == "string" then $content
      elif $content | type == "array" then
        [$content[] | select(.type == "text") | .text] | join("\n")
      else "" end
    ) as $text

  | select($text | length > 0)
  | "[\($role)] \($text)"
' "$TRANSCRIPT" 2>/dev/null \
| sed -E 's|<system-reminder>[^<]*</system-reminder>||g' \
| sed -E 's|<system-reminder>.*$||g' \
| sed -E 's|<local-command-[a-z]+>[^<]*</local-command-[a-z]+>||g' \
| grep -v '^$' \
| grep -v '^\[unknown\]' || true
