#!/usr/bin/env bash
# dream-skill vault progress reporter.
# Appends ONE human-readable entry per run to the day's report file in the
# vault's dream-reports/ folder, so dream-skill activity is visible in Obsidian.
# Best-effort: ALWAYS exits 0; never breaks the caller (trigger.sh is
# fire-and-forget; the auto skill must not crash on a report failure).
#
# Usage:
#   report.sh --status <wrote|noop|skipped|error> --chat "<label>" \
#             [--reason "<text>"] [--time "<HH:MM TZ>"] [--reports-dir <dir>]
#   # When --status wrote, the [WRITE]/[QUEUE]/[DROP] body lines are read from stdin.
#
# Reports dir resolution: --reports-dir -> $DREAM_REPORTS_DIR -> config reports_dir
#   -> <Obsidian root>/dream-reports (parent of the first configured vault root).

set -uo pipefail   # deliberately NOT -e: best-effort, must always reach exit 0

STATUS=""; CHAT=""; REASON=""; TIME_STR=""; REPORTS_DIR_ARG=""; TITLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --status)      STATUS="${2:-}"; shift 2 ;;
    --chat)        CHAT="${2:-}"; shift 2 ;;
    --title)       TITLE="${2:-}"; shift 2 ;;
    --reason)      REASON="${2:-}"; shift 2 ;;
    --time)        TIME_STR="${2:-}"; shift 2 ;;
    --reports-dir) REPORTS_DIR_ARG="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

ERROR_LOG="${DREAM_ERROR_LOG:-$HOME/.claude/dream-skill/error.log}"
note_err() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) report.sh: $*" >> "$ERROR_LOG" 2>/dev/null || true; }

resolve_reports_dir() {
  if [ -n "$REPORTS_DIR_ARG" ]; then printf '%s' "$REPORTS_DIR_ARG"; return; fi
  if [ -n "${DREAM_REPORTS_DIR:-}" ]; then printf '%s' "$DREAM_REPORTS_DIR"; return; fi
  local cfg="${DREAM_CONFIG:-$HOME/.claude/dream-skill/config.toml}"
  local explicit first_root
  explicit=$(grep -E '^[[:space:]]*reports_dir[[:space:]]*=' "$cfg" 2>/dev/null | head -1 \
             | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return; fi
  first_root=$(grep -E '^[[:space:]]*root[[:space:]]*=' "$cfg" 2>/dev/null | head -1 \
               | sed -E 's/.*"([^"]*)".*/\1/')
  if [ -n "$first_root" ]; then printf '%s/dream-reports' "$(dirname "$first_root")"; return; fi
  printf ''
}

[ -n "$STATUS" ] || { note_err "missing --status"; exit 0; }

REPORTS_DIR="$(resolve_reports_dir)"
[ -n "$REPORTS_DIR" ] || { note_err "could not resolve reports dir"; exit 0; }
mkdir -p "$REPORTS_DIR" 2>/dev/null || { note_err "cannot create $REPORTS_DIR"; exit 0; }

DATE="$(date +%Y-%m-%d)"                       # local date for the filename
TIME_STR="${TIME_STR:-$(date +'%H:%M %Z')}"    # local time for the entry
FILE="$REPORTS_DIR/dream-$DATE.md"

# Create the day file with frontmatter + H1 exactly once (noclobber = race-safe).
( set -o noclobber
  printf -- '---\ntype: dream-activity-log\ndate: %s\n---\n\n# Dream activity — %s\n' "$DATE" "$DATE" > "$FILE"
) 2>/dev/null || true
[ -f "$FILE" ] || { note_err "cannot write $FILE"; exit 0; }

# Optional body (stdin), meaningful only for --status wrote.
BODY=""
[ -t 0 ] || BODY="$(cat 2>/dev/null || true)"

case "$STATUS" in
  wrote)
    n=$(printf '%s\n' "$BODY" | grep -cE '^[[:space:]]*-[[:space:]]*\[WRITE\]' 2>/dev/null) || n=0
    head_status="wrote $n" ;;
  noop)    head_status="ran, 0 writes" ;;
  skipped) head_status="skipped" ;;
  error)   head_status="error" ;;
  *)       head_status="$STATUS" ;;
esac

# Assemble incrementally: each piece embeds the previous via "%s\n<new>" so the
# newline is a SEPARATOR. (Command substitution strips trailing newlines, so a
# naive "$ENTRY$(printf 'reason...\n')" would glue lines together.)
ENTRY="$(printf '\n### %s — %s\nchat: %s' "$TIME_STR" "$head_status" "${CHAT:-unknown}")"
if [ -n "$TITLE" ]; then
  ENTRY="$(printf '%s\ntitle: %s' "$ENTRY" "$TITLE")"
fi
if [ "$STATUS" = "wrote" ] && [ -n "$BODY" ]; then
  ENTRY="$(printf '%s\ncontents:\n%s' "$ENTRY" "$BODY")"
elif [ -n "$REASON" ]; then
  ENTRY="$(printf '%s\nreason: %s' "$ENTRY" "$REASON")"
fi

# Single O_APPEND write; entries are < PIPE_BUF (4 KB), so concurrent appends
# do not interleave on a local filesystem.
printf '%s\n' "$ENTRY" >> "$FILE" 2>/dev/null || note_err "append failed $FILE"
exit 0
