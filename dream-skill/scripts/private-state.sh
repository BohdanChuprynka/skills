#!/usr/bin/env bash
# dream-skill private-chat state resolver.
#
# Prints "ignore" if the chat is currently marked private, else "record".
# State = the LAST `/dream-skill --ignore` / `--unignore` the user typed
# (latest-wins): a chat is private iff its most recent toggle is --ignore.
#
# Detection only counts a GENUINE typed slash command: a user-role, non-meta
# record whose content is a STRING carrying the dream-skill command-name AND the
# flag inside a <command-args> tag. That string-content-user-record requirement is
# the load-bearing guard — chats that merely quote the serialization land as
# tool_result ARRAYS or ASSISTANT records and are excluded, so the skill's own help
# text / description (which ride in every transcript) and a Read/Write of these
# files can never mark a chat private. Bias is toward DETECT (privacy-safe): on any
# ambiguity we'd rather skip recording than leak a private chat.
#
# Always exits 0; never crashes the fire-and-forget caller.

set -uo pipefail

TRANSCRIPT="${1:-}"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || { echo "record"; exit 0; }

state=""
if command -v jq >/dev/null 2>&1; then
  # Emit "ignore"/"unignore" per genuine toggle record, in file order; last wins.
  state=$(jq -rR '
    fromjson?
    | (.message.content // .content) as $c
    | ((.message.role // .role) // "") as $r
    | ((.isMeta // false) or (.isCompactSummary // false)) as $meta
    | select($r == "user" and ($meta | not) and (($c | type) == "string")
        and ($c | test("<command-name>/dream-skill</command-name>"))
        and ($c | test("<command-args>[^<]*--(un)?ignore")))
    | (if ($c | test("<command-args>[^<]*--unignore")) then "unignore" else "ignore" end)
  ' "$TRANSCRIPT" 2>/dev/null | tail -1)
else
  # jq missing: coarse line grep. May over-detect in a (jq-less) chat that quotes
  # the raw serialization — acceptable, privacy-safe degradation.
  last=$(grep -aE '<command-name>/dream-skill</command-name>.*<command-args>[^<]*--(un)?ignore' "$TRANSCRIPT" 2>/dev/null | tail -1 || true)
  if [ -n "$last" ]; then
    if printf '%s' "$last" | grep -q -- '--unignore'; then state="unignore"; else state="ignore"; fi
  fi
fi

case "$state" in
  ignore) echo "ignore" ;;
  *)      echo "record" ;;   # "unignore" or none → record normally
esac
exit 0
