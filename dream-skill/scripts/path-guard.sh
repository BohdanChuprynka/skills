#!/usr/bin/env bash
# dream-skill — shared path-confinement guard.
#
# Vault page paths flow from LLM routing/reconciliation output (.target.page),
# so they are UNTRUSTED. A hallucinated or malformed value like "../../escape.md"
# must never let vault-writer / apply-undo write OUTSIDE the configured vault root.
#
# Source this file, then call:  assert_within_vault "<vault-root>" "<relative-page>"
# On any escape it prints to stderr and exits 1 (aborting the caller, which runs
# under `set -e`). This is a sourced library: it intentionally sets no shell opts.

assert_within_vault() {
  local vault="$1" page="$2"

  # 1. No absolute page paths — page must be relative to the vault root.
  case "$page" in
    /*) echo "path-guard: refusing absolute page path: $page" >&2; exit 1 ;;
  esac

  # 2. No ".." path segment (the real traversal vector). Wrapping in slashes makes
  #    the pattern match ".." only as a whole segment, not inside a filename like
  #    "v1..2-notes.md".
  case "/$page/" in
    */../*) echo "path-guard: refusing '..' traversal in page path: $page" >&2; exit 1 ;;
  esac

  # 3. No symlinked LEAF — a write would follow the page symlink out of the vault even
  #    though its parent dir is in-vault. `-L` is true for dangling symlinks too, so
  #    this covers both "link → existing outside file" and "link → not-yet-created".
  if [ -L "$vault/$page" ]; then
    echo "path-guard: refusing symlinked page target: $page" >&2; exit 1
  fi

  # 4. Resolve the DEEPEST EXISTING ancestor of the target and assert it sits under
  #    the vault root's real path. Walk up (not just the immediate parent) AND stop at
  #    any symlink — even a dangling one — so a symlinked intermediate dir can't let
  #    `mkdir -p` create a path OUTSIDE the vault. A symlink we stop on is then resolved
  #    by `cd; pwd -P` (dangling → cd fails → reject).
  local vault_real dir anc_real
  vault_real="$(cd "$vault" 2>/dev/null && pwd -P)" \
    || { echo "path-guard: cannot resolve vault root: $vault" >&2; exit 1; }
  dir="$(dirname "$vault/$page")"
  while [ ! -d "$dir" ] && [ ! -L "$dir" ]; do dir="$(dirname "$dir")"; done
  anc_real="$(cd "$dir" 2>/dev/null && pwd -P)" \
    || { echo "path-guard: cannot resolve target dir (broken symlink?): $dir" >&2; exit 1; }
  case "$anc_real/" in
    "$vault_real"/*) ;;  # deepest existing ancestor is inside the vault root — ok
    *) echo "path-guard: page escapes vault root: $page -> $anc_real (outside $vault_real)" >&2; exit 1 ;;
  esac
}
