#!/usr/bin/env bash
#
# scrub-history.sh — PERMANENTLY purge deleted internal planning/spec docs from
# this repo's git history. Those files were `git rm`'d but remain readable in
# history and contain personal profile data (schedule, town, internship).
#
# ⚠️  DESTRUCTIVE & IRREVERSIBLE:
#   - Rewrites every commit hash (history rewrite).
#   - Requires a force-push, which invalidates all existing clones and forks.
#   - GitHub keeps cached blob views even after a force-push; to purge those you
#     must open a GitHub Support request referencing the old commit SHAs.
#
# This script does NOTHING without `--confirm`. It NEVER pushes — it prints the
# exact push command for you to run manually after you have verified the result.
#
# Prereq:  pip install git-filter-repo   (or: brew install git-filter-repo)
# Usage:   bash scrub-history.sh            # dry preview, no changes
#          bash scrub-history.sh --confirm  # perform the local history rewrite

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

# Exact set of sensitive paths to purge from ALL history (verified present in
# history as of this writing via: git log --all --diff-filter=D --name-only).
PATHS=(
  "dream-skill/PLAN.md"
  "dream-skill/PLAN-v0.3.md"
  "dream-skill/PLAN-warning-system.md"
  "dream-skill/PLAN-01-vault-writer-edit-2026-06-03.md"
  "dream-skill/PLAN-02-router-2026-06-03.md"
  "dream-skill/PLAN-03-reconciler-2026-06-03.md"
  "dream-skill/PLAN-04-orchestrator-2026-06-03.md"
  "dream-skill/PLAN-OVERVIEW-2026-06-03.md"
  "dream-skill/REDESIGN-2026-06-03-on-demand-batch.md"
  "dream-skill/docs/superpowers/plans/2026-05-26-dream-skill-map-reduce.md"
  "dream-skill/docs/superpowers/plans/2026-05-29-dream-report-vault-progress.md"
  "dream-skill/docs/superpowers/specs/2026-05-26-dream-skill-map-reduce-design.md"
  "dream-skill/docs/superpowers/specs/2026-05-29-dream-report-vault-progress-design.md"
  "dream-skill/docs/superpowers/specs/2026-06-02-dream-skill-private-chats-design.md"
)

echo "Will purge the following ${#PATHS[@]} path(s) from ALL of this repo's history:"
printf '  - %s\n' "${PATHS[@]}"
echo

if ! command -v git-filter-repo >/dev/null 2>&1; then
  echo "ERROR: git-filter-repo is not installed."
  echo "  Install:  pip install git-filter-repo   (or: brew install git-filter-repo)"
  exit 1
fi

if [[ "${1:-}" != "--confirm" ]]; then
  echo "DRY PREVIEW — nothing changed. Re-run with --confirm to rewrite local history."
  echo "Strongly recommended: back up first ->  git clone --mirror . ../skills-backup.git"
  exit 0
fi

# Build the --path args.
ARGS=()
for p in "${PATHS[@]}"; do ARGS+=(--path "$p"); done

echo "Rewriting history locally (this does NOT touch the remote)…"
git filter-repo --invert-paths "${ARGS[@]}" --force

cat <<'NEXT'

Local history rewritten. NOTHING has been pushed.

Now:
  1. Verify the result, e.g.:
       git log --all --diff-filter=D --name-only --pretty=format: | grep -E 'PLAN|REDESIGN|superpowers' || echo "clean"
  2. git-filter-repo removes 'origin' for safety. Re-add it:
       git remote add origin https://github.com/BohdanChuprynka/skills.git
  3. When satisfied, force-push every branch and tag (IRREVERSIBLE):
       git push origin --force --all
       git push origin --force --tags
  4. Open a GitHub Support request to purge cached blob views of the old SHAs.
  5. Tell any collaborators/forks to re-clone — their old clones are now incompatible.
NEXT
