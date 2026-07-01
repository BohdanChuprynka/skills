#!/usr/bin/env bash
# dream-skill private-chat state resolver.
#
# Prints "ignore" if the chat is currently marked private, else "record".
# State = the LAST `/dream-skill --ignore` / `--unignore` the user typed
# (latest-wins): a chat is private iff its most recent toggle is --ignore.
#
# Detection only counts a GENUINE typed command in a user-visible record:
# - Claude Code serialized slash commands carry <command-name>/dream-skill</...>
#   plus the flag inside <command-args>.
# - Codex user messages carry text like `Use $dream-skill --ignore` or
#   `/dream-skill --ignore`.
# Chats that merely quote the command from tool output or assistant messages are
# excluded when jq is available. Bias is toward DETECT (privacy-safe): on any
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
    | (.payload // {}) as $p
    | (($p.message // .message.content // .content) // "") as $c
    | (($p.role // .message.role // .role) // "") as $r
    | (($p.type // "") == "user_message") as $codex_user
    | ((.isMeta // false) or (.isCompactSummary // false)) as $meta
    | select((($r == "user") or $codex_user) and ($meta | not) and (($c | type) == "string")
        and (
          (($c | test("<command-name>/dream-skill</command-name>"))
            and ($c | test("<command-args>[^<]*--(un)?ignore")))
          or ($c | test("(^|\\n)[[:space:]]*(/dream-skill|[Uu]se[[:space:]]+\\$dream-skill)([[:space:]][^\\n]*)?--(un)?ignore($|[[:space:]])"))
        ))
    | (if ($c | test("<command-args>[^<]*--unignore")) then "unignore" else "ignore" end)
    | (if ($c | test("(^|\\n)[[:space:]]*(/dream-skill|[Uu]se[[:space:]]+\\$dream-skill)([[:space:]][^\\n]*)?--unignore($|[[:space:]])")) then "unignore" else . end)
  ' "$TRANSCRIPT" 2>/dev/null | tail -1)
else
  # jq missing: coarse line grep. May over-detect in a (jq-less) chat that quotes
  # the raw serialization — acceptable, privacy-safe degradation.
  last=$(grep -aE '(<command-name>/dream-skill</command-name>.*<command-args>[^<]*--(un)?ignore|(^|[[:space:]])(/dream-skill|[Uu]se[[:space:]]+\$dream-skill)([[:space:]][^"]*)?--(un)?ignore)' "$TRANSCRIPT" 2>/dev/null | tail -1 || true)
  if [ -n "$last" ]; then
    if printf '%s' "$last" | grep -q -- '--unignore'; then state="unignore"; else state="ignore"; fi
  fi
fi

case "$state" in
  ignore) echo "ignore" ;;
  *)      echo "record" ;;   # "unignore" or none → record normally
esac
exit 0
