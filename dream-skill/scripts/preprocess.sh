#!/usr/bin/env bash
# dream-skill transcript preprocessor.
# Reads a Claude Code transcript JSONL file; emits cleaned plain-text
# on stdout. Keeps user + assistant text content only.
# LLM-judgment filtering (code-vs-concept, Q&A signal, brainstormed
# ideas) happens in the SKILL.md flow, not here.

set -euo pipefail

TRANSCRIPT="${1:?usage: preprocess.sh <transcript.jsonl>}"
[ -f "$TRANSCRIPT" ] || { echo "no such file: $TRANSCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

# Per-line: extract role + only text-type content.
# - If .content is a string → use as-is
# - If .content is an array → keep only items where .type == "text", join their .text
# - Drop tool_use, tool_result, image, thinking, anything else
# Then strip <system-reminder>...</system-reminder> tags and blank lines.

jq -r '
  . as $line
  | (.role // "unknown") as $role
  | (.content
      | if type == "string" then .
        elif type == "array" then
          [.[] | select(.type == "text") | .text] | join("\n")
        else "" end
    ) as $text
  | if ($text | length) > 0 then "[\($role)] \($text)" else empty end
' "$TRANSCRIPT" 2>/dev/null \
| sed -E 's|<system-reminder>[^<]*</system-reminder>||g' \
| sed -E 's|<system-reminder>.*$||g' \
| grep -v '^$' \
| grep -v '^\[unknown\]' || true
