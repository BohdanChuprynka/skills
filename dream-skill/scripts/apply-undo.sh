#!/usr/bin/env bash
# dream-skill apply-undo.
# Reverses vault-writer.sh actions recorded in an undo log (JSONL).
# Reads entries in reverse order; for each:
#   action=append      → remove "- <content>" from <vault>/<page>
#   action=remove      → reinsert "- <content>" under the recorded section
#   action=replace     → swap "- <content>" back to "- <old_content>" in <vault>/<page>
#   action=index_append → remove the inserted line from the index file
# Prints summary of reverted entries.
#
# Usage:
#   apply-undo.sh <undo-log-path>
#   apply-undo.sh --run-id <run-id> [--home <DREAM_HOME>]
#   apply-undo.sh --date <YYYY-MM-DD> --allow-legacy-date [--home <DREAM_HOME>]

set -euo pipefail

# Shared path-confinement guard (defends against a tampered/corrupt undo log).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/path-guard.sh"

die() { echo "apply-undo: $*" >&2; exit 1; }

UNDO_LOG=""
DREAM_ROOT="${DREAM_HOME:-$HOME/.claude/dream-skill}"
REQUESTED_RUN_ID=""
LEGACY_DATE=""
ALLOW_LEGACY_DATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "missing value after --home"; DREAM_ROOT="$2"; shift 2 ;;
    --run-id) [ $# -ge 2 ] || die "missing value after --run-id"; REQUESTED_RUN_ID="$2"; shift 2 ;;
    --date) [ $# -ge 2 ] || die "missing value after --date"; LEGACY_DATE="$2"; shift 2 ;;
    --allow-legacy-date) ALLOW_LEGACY_DATE=1; shift ;;
    --*) die "unknown arg: $1" ;;
    *)
      [ -z "$UNDO_LOG" ] || die "only one explicit undo-log path may be supplied"
      UNDO_LOG="$1"
      shift
      ;;
  esac
done

[ -z "$REQUESTED_RUN_ID" ] || [ -z "$LEGACY_DATE" ] \
  || die "--run-id and --date are mutually exclusive"
[ -z "$UNDO_LOG" ] || { [ -z "$REQUESTED_RUN_ID$LEGACY_DATE" ] \
  || die "explicit undo-log path cannot be combined with --run-id/--date"; }

if [ -n "$REQUESTED_RUN_ID" ]; then
  case "$REQUESTED_RUN_ID" in
    ""|[._-]*|*[!A-Za-z0-9._-]*) die "unsafe run id: $REQUESTED_RUN_ID" ;;
  esac
  [ "${#REQUESTED_RUN_ID}" -le 128 ] || die "run id is too long"
  UNDO_LOG="$DREAM_ROOT/undo/$REQUESTED_RUN_ID.jsonl"
elif [ -n "$LEGACY_DATE" ]; then
  [ "$ALLOW_LEGACY_DATE" = "1" ] \
    || die "date-scoped rollback is legacy and may span runs; add --allow-legacy-date explicitly"
  case "$LEGACY_DATE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die "invalid legacy date: $LEGACY_DATE" ;;
  esac
  UNDO_LOG="$DREAM_ROOT/undo/$LEGACY_DATE.jsonl"
fi

[ -n "$UNDO_LOG" ] || die "usage: apply-undo.sh <undo-log-path>|--run-id <run-id> [--home <DREAM_HOME>]"

[ -f "$UNDO_LOG" ] || die "undo log not found: $UNDO_LOG"
[ ! -L "$UNDO_LOG" ] || die "refusing symlinked undo log: $UNDO_LOG"
command -v jq >/dev/null 2>&1 || die "jq required"

# Reverse one content/index mutation and its freshness metadata in a single
# same-directory temp + rename. Legacy entries without .frontmatter still undo
# their content and leave YAML untouched.
_rewrite_atomic() {
  local file="$1" kind="$2" match="$3" replacement="$4" event_json="$5"
  local expected_fm had_updated prior tmp
  expected_fm=$(printf '%s\n' "$event_json" | jq -r '.frontmatter.present_before // false')
  had_updated=$(printf '%s\n' "$event_json" | jq -r '.frontmatter.had_updated_before // false')
  prior=$(printf '%s\n' "$event_json" | jq -r '.frontmatter.updated_before // ""')
  tmp="$file.undo.$$"
  if transform_kind="$kind" transform_match="$match" transform_replacement="$replacement" \
     expected_fm="$expected_fm" had_updated="$had_updated" prior_updated="$prior" awk '
    BEGIN {
      kind=ENVIRON["transform_kind"]
      needle=ENVIRON["transform_match"]
      replacement=ENVIRON["transform_replacement"]
      expect_fm=ENVIRON["expected_fm"]
      had=ENVIRON["had_updated"]
      prior=ENVIRON["prior_updated"]
      in_fm=0; saw_open=0; saw_close=0; saw_updated=0; changed=0
    }
    NR == 1 && $0 == "---" && expect_fm == "true" {
      saw_open=1; in_fm=1; print; next
    }
    in_fm && $0 == "---" {
      if (!saw_updated && had == "true") print prior
      saw_close=1; in_fm=0; print; next
    }
    in_fm && /^updated:[[:space:]]*/ && !saw_updated {
      if (had == "true") print prior
      saw_updated=1
      next
    }
    !changed && $0 == needle {
      if (kind == "replace") print replacement
      changed=1
      next
    }
    { print }
    END {
      if (!changed) exit 42
      if (expect_fm == "true" && (!saw_open || !saw_close)) exit 43
    }
  ' "$file" > "$tmp"; then
    mv -f "$tmp" "$file"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_insert_atomic() {
  local file="$1" section="$2" inserted_line="$3" event_json="$4"
  local expected_fm had_updated prior tmp previous next anchor mode
  expected_fm=$(printf '%s\n' "$event_json" | jq -r '.frontmatter.present_before // false')
  had_updated=$(printf '%s\n' "$event_json" | jq -r '.frontmatter.had_updated_before // false')
  prior=$(printf '%s\n' "$event_json" | jq -r '.frontmatter.updated_before // ""')
  previous=$(printf '%s\n' "$event_json" | jq -r '.previous_line // ""')
  next=$(printf '%s\n' "$event_json" | jq -r '.next_line // ""')
  anchor="## $section"
  mode="after"
  if [ -n "$next" ] && grep -Fxq -- "$next" "$file"; then
    anchor="$next"
    mode="before"
  elif [ -n "$previous" ] && grep -Fxq -- "$previous" "$file"; then
    anchor="$previous"
    mode="after"
  fi
  tmp="$file.undo.$$"
  if insert_anchor="$anchor" insert_mode="$mode" insert_line="$inserted_line" \
     expected_fm="$expected_fm" had_updated="$had_updated" prior_updated="$prior" awk '
    BEGIN {
      anchor=ENVIRON["insert_anchor"]; mode=ENVIRON["insert_mode"]; newline=ENVIRON["insert_line"]
      expect_fm=ENVIRON["expected_fm"]; had=ENVIRON["had_updated"]
      prior=ENVIRON["prior_updated"]
      in_fm=0; saw_open=0; saw_close=0; saw_updated=0; inserted=0
    }
    NR == 1 && $0 == "---" && expect_fm == "true" {
      saw_open=1; in_fm=1; print; next
    }
    in_fm && $0 == "---" {
      if (!saw_updated && had == "true") print prior
      saw_close=1; in_fm=0; print; next
    }
    in_fm && /^updated:[[:space:]]*/ && !saw_updated {
      if (had == "true") print prior
      saw_updated=1
      next
    }
    !inserted && $0 == anchor && mode == "before" { print newline; print; inserted=1; next }
    !inserted && $0 == anchor && mode == "after" { print; print newline; inserted=1; next }
    { print }
    END {
      if (!inserted) exit 42
      if (expect_fm == "true" && (!saw_open || !saw_close)) exit 43
    }
  ' "$file" > "$tmp"; then
    mv -f "$tmp" "$file"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Validate the schema required by each action before resolving any target. Core
# mutation fields are mandatory even for legacy logs. Run-scoped logs also
# require the provenance and freshness fields emitted by the modern writer.
_validate_event_schema() {
  local event="$1" modern=false
  [ -n "$REQUESTED_RUN_ID" ] && modern=true
  printf '%s\n' "$event" | jq -e --argjson modern "$modern" '
    def line:
      type == "string" and length > 0 and
      (contains("\n") | not) and (contains("\r") | not);
    def optional_line:
      type == "string" and (contains("\n") | not) and (contains("\r") | not);
    def valid_frontmatter:
      type == "object" and
      (.present_before | type == "boolean") and
      (.had_updated_before | type == "boolean") and
      ((.updated_before == null) or (.updated_before | line)) and
      ((.updated_applied == null) or
        ((.updated_applied | type == "string") and
         (.updated_applied | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))) and
      (if .had_updated_before then
         (.present_before and (.updated_before | startswith("updated:")))
       else .updated_before == null end) and
      (if .present_before then .updated_applied != null
       else .updated_applied == null end);
    type == "object" and
    (.action as $a | ["append", "remove", "replace", "index_append"] | index($a) != null) and
    (.vault | line) and
    (if .action == "append" then
       (.page | line) and (.content | line) and
       ((has("section") | not) or (.section | line))
     elif .action == "remove" then
       (.page | line) and (.content | line) and (.section | line) and
       ((has("previous_line") | not) or (.previous_line | optional_line)) and
       ((has("next_line") | not) or (.next_line | optional_line)) and
       ((has("line_number_before") | not) or
         ((.line_number_before | type == "number") and .line_number_before >= 0))
     elif .action == "replace" then
       (.page | line) and (.content | line) and (.old_content | line) and
       ((has("section") | not) or (.section | line))
     else
       (.index_file | line) and (.line | line)
     end) and
    ((has("frontmatter") | not) or (.frontmatter | valid_frontmatter)) and
    (if $modern then
       (.timestamp | line) and (.run_id | line) and (.candidate_id | line) and
       has("frontmatter")
     else true end)
  ' >/dev/null
}

_validate_index_target() {
  local vault="$1" index_file="$2" vault_real index_dir
  [ -d "$vault" ] || return 1
  [ -f "$index_file" ] && [ ! -L "$index_file" ] || return 1
  vault_real="$(cd "$vault" 2>/dev/null && pwd -P || true)"
  index_dir="$(cd "$(dirname "$index_file")" 2>/dev/null && pwd -P || true)"
  [ -n "$vault_real" ] && [ -n "$index_dir" ] || return 1
  case "$index_dir/" in
    "$vault_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_event_target_path() {
  local event="$1" action vault page index_file
  action=$(printf '%s\n' "$event" | jq -r '.action')
  vault=$(printf '%s\n' "$event" | jq -r '.vault')
  if [ "$action" = "index_append" ]; then
    index_file=$(printf '%s\n' "$event" | jq -r '.index_file')
    _validate_index_target "$vault" "$index_file" \
      || die "unsafe or missing index target: $index_file"
    printf '%s\n' "$index_file"
  else
    page=$(printf '%s\n' "$event" | jq -r '.page')
    ( assert_within_vault "$vault" "$page" ) 2>/dev/null \
      || die "unsafe page target: $page"
    [ -f "$vault/$page" ] && [ ! -L "$vault/$page" ] \
      || die "missing or symlinked page target: $page"
    printf '%s\n' "$vault/$page"
  fi
}

_validate_expected_frontmatter() {
  local file="$1" event="$2" present applied closing count
  if ! printf '%s\n' "$event" | jq -e 'has("frontmatter")' >/dev/null; then
    return 0
  fi
  present=$(printf '%s\n' "$event" | jq -r '.frontmatter.present_before')
  [ "$present" = "true" ] || return 0
  [ "$(sed -n '1p' "$file")" = "---" ] || return 1
  closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$file")
  [ -n "$closing" ] || return 1
  applied=$(printf '%s\n' "$event" | jq -r '.frontmatter.updated_applied')
  count=$(awk -v stop="$closing" -v wanted="updated: $applied" '
    NR > 1 && NR < stop && $0 == wanted { n++ }
    END { print n + 0 }
  ' "$file")
  [ "$count" -eq 1 ]
}

# Apply one already-validated reverse event to FILE. This helper is used first
# on private staging copies, then on the real files, so every expected content
# state and freshness transition is proven before the first vault mutation.
_apply_event_to_file() {
  local file="$1" event="$2" action content section target old new match replacement count
  local previous next anchor
  action=$(printf '%s\n' "$event" | jq -r '.action')
  case "$action" in
    append)
      content=$(printf '%s\n' "$event" | jq -r '.content')
      target="- $content"
      count=$(grep -Fxc -- "$target" "$file" || true)
      [ "$count" -eq 1 ] || return 1
      _rewrite_atomic "$file" remove "$target" "" "$event"
      ;;
    remove)
      content=$(printf '%s\n' "$event" | jq -r '.content')
      section=$(printf '%s\n' "$event" | jq -r '.section')
      target="- $content"
      ! grep -Fxq -- "$target" "$file" || return 1
      previous=$(printf '%s\n' "$event" | jq -r '.previous_line // ""')
      next=$(printf '%s\n' "$event" | jq -r '.next_line // ""')
      anchor="## $section"
      if [ -n "$next" ] && grep -Fxq -- "$next" "$file"; then
        anchor="$next"
      elif [ -n "$previous" ] && grep -Fxq -- "$previous" "$file"; then
        anchor="$previous"
      fi
      count=$(grep -Fxc -- "$anchor" "$file" || true)
      [ "$count" -eq 1 ] || return 1
      _insert_atomic "$file" "$section" "$target" "$event"
      ;;
    replace)
      old=$(printf '%s\n' "$event" | jq -r '.old_content')
      new=$(printf '%s\n' "$event" | jq -r '.content')
      match="$new"
      replacement="$old"
      if ! grep -Fxq -- "$match" "$file" && [ -z "$REQUESTED_RUN_ID" ]; then
        match="- $new"
        replacement="- $old"
      fi
      count=$(grep -Fxc -- "$match" "$file" || true)
      [ "$count" -eq 1 ] || return 1
      ! grep -Fxq -- "$replacement" "$file" || return 1
      _rewrite_atomic "$file" replace "$match" "$replacement" "$event"
      ;;
    index_append)
      target=$(printf '%s\n' "$event" | jq -r '.line')
      count=$(grep -Fxc -- "$target" "$file" || true)
      [ "$count" -eq 1 ] || return 1
      _rewrite_atomic "$file" remove "$target" "" "$event"
      ;;
    *) return 1 ;;
  esac
}

REVERSE_LOG=$(mktemp "${TMPDIR:-/tmp}/dream-undo-reverse.XXXXXX")
PREFLIGHT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dream-undo-preflight.XXXXXX")
trap 'rm -f "${REVERSE_LOG:-}"; rm -rf "${PREFLIGHT_DIR:-}"' EXIT

# Phase 1: validate every JSON object, action schema, provenance boundary, and
# confined target. Nothing under a vault is mutated in this phase.
EVENT_COUNT=0
while IFS= read -r _verify_line; do
  EVENT_COUNT=$((EVENT_COUNT + 1))
  [ -n "$_verify_line" ] || die "blank undo event at line $EVENT_COUNT"
  _validate_event_schema "$_verify_line" \
    || die "invalid undo event schema at line $EVENT_COUNT"
  if [ -n "$REQUESTED_RUN_ID" ]; then
    _event_run=$(printf '%s\n' "$_verify_line" | jq -r '.run_id')
    [ "$_event_run" = "$REQUESTED_RUN_ID" ] \
      || die "undo log run_id mismatch: expected $REQUESTED_RUN_ID, found $_event_run"
  fi
  _event_target_path "$_verify_line" >/dev/null
done < "$UNDO_LOG"
[ "$EVENT_COUNT" -gt 0 ] || die "undo log is empty"

# Reverse order: undo most recent first.
tac "$UNDO_LOG" 2>/dev/null > "$REVERSE_LOG" ||
  awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}' "$UNDO_LOG" > "$REVERSE_LOG"

_staged_copy() {
  local source="$1" digest staged
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$source" | shasum -a 256 | awk '{print $1}')
  else
    digest=$(printf '%s' "$source" | cksum | awk '{print $1}')
  fi
  staged="$PREFLIGHT_DIR/$digest"
  if [ ! -f "$staged.ready" ]; then
    cp "$source" "$staged"
    : > "$staged.ready"
  fi
  printf '%s\n' "$staged"
}

# Phase 2: replay the complete rollback against private copies. This catches a
# stale/missing expected line, ambiguous anchor, or incompatible freshness state
# before any real page is touched.
while IFS= read -r _verify_line; do
  _target=$(_event_target_path "$_verify_line")
  _staged=$(_staged_copy "$_target")
  _validate_expected_frontmatter "$_staged" "$_verify_line" \
    || die "frontmatter state no longer matches undo event for $_target"
  _apply_event_to_file "$_staged" "$_verify_line" \
    || die "content state no longer matches undo event for $_target"
done < "$REVERSE_LOG"

REVERTED=0

while IFS= read -r line; do
  _target=$(_event_target_path "$line")
  _validate_expected_frontmatter "$_target" "$line" \
    || die "frontmatter changed after rollback preflight for $_target"
  _apply_event_to_file "$_target" "$line" \
    || die "content changed after rollback preflight for $_target"
  REVERTED=$((REVERTED + 1))
done < "$REVERSE_LOG"

# Move the processed log aside so it can't be re-applied accidentally
mv "$UNDO_LOG" "$UNDO_LOG.applied-$(date -u +%Y%m%dT%H%M%SZ)"

echo "Reverted: $REVERTED entries (skipped: 0)"
echo "Processed log moved to: ${UNDO_LOG}.applied-*"
