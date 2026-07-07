#!/usr/bin/env bash
#
# route-to-codex.sh — the execution stage of routing-mode.
#
# Hands an approved implementation plan to the Codex CLI (OpenAI) for coding,
# then prints the resulting git diff for review. Planning and verification stay
# with Claude; this script is only the cheap-model execution hop.
#
# Usage:
#   route-to-codex.sh <plan-file> [extra-instructions...]
#   route-to-codex.sh <plan-file> -- "free-form corrective instructions"
#   route-to-codex.sh --help
#
# Config (environment variable, or flag; the flag wins):
#   ROUTING_MODEL        default gpt-5.5                 -m | --model <id>
#   ROUTING_EFFORT       default high                    --effort <low|medium|high|xhigh>
#   ROUTING_SANDBOX      default danger-full-access      -s | --sandbox <mode>
#                        modes: danger-full-access | workspace-write | read-only
#   ROUTING_ALLOW_DIRTY  default 0                        --allow-dirty
#
# SECURITY: the default sandbox is danger-full-access — Codex runs arbitrary
# shell with NO sandbox (network, package installs, deletes). The safety rail is
# that this script refuses to run unless you are inside a git repo with a clean
# working tree, so every change Codex makes is a reviewable, revertable diff.
# To reduce blast radius, set ROUTING_SANDBOX=workspace-write.

set -euo pipefail

MODEL="${ROUTING_MODEL:-gpt-5.5}"
EFFORT="${ROUTING_EFFORT:-high}"
SANDBOX="${ROUTING_SANDBOX:-danger-full-access}"
ALLOW_DIRTY="${ROUTING_ALLOW_DIRTY:-0}"

die() { printf 'routing-mode: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'USAGE'
route-to-codex.sh — routing-mode execution stage

Usage:
  route-to-codex.sh <plan-file> [extra-instructions...]
  route-to-codex.sh <plan-file> -- "free-form corrective instructions"

Options:
  -m, --model <id>        Codex model (default: gpt-5.5, or $ROUTING_MODEL)
      --effort <level>    Reasoning effort low|medium|high|xhigh (default: high)
  -s, --sandbox <mode>    danger-full-access|workspace-write|read-only
                          (default: danger-full-access, or $ROUTING_SANDBOX)
      --allow-dirty       Run even if the git working tree is dirty (unsafe)
  -h, --help              Show this help
USAGE
}

# --- parse args ---
PLAN=""
EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -m|--model) [ $# -ge 2 ] || die "missing value for $1"; MODEL="$2"; shift 2 ;;
    --effort) [ $# -ge 2 ] || die "missing value for $1"; EFFORT="$2"; shift 2 ;;
    -s|--sandbox) [ $# -ge 2 ] || die "missing value for $1"; SANDBOX="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --) shift; EXTRA="$*"; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) if [ -z "$PLAN" ]; then PLAN="$1"; else EXTRA="${EXTRA:+$EXTRA }$1"; fi; shift ;;
  esac
done

[ -n "$PLAN" ] || { usage >&2; die "no plan file given"; }
[ -f "$PLAN" ] || die "plan file not found: $PLAN"
PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

# --- preflight: codex present + authenticated ---
command -v codex >/dev/null 2>&1 \
  || die "codex CLI not found on PATH. Install it: npm install -g @openai/codex (see docs/installing-codex-cli.md)"
if [ ! -f "$HOME/.codex/auth.json" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  die "Codex is not authenticated. Run 'codex login', or export OPENAI_API_KEY (see docs/installing-codex-cli.md)"
fi

# --- preflight: git repo + clean tree (the safety rail) ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git repo. routing-mode requires git so Codex's changes stay reviewable and revertable"
if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  die "working tree is dirty. Commit or stash first (so the diff is only Codex's work), or pass --allow-dirty"
fi
BEFORE="$(git rev-parse --short HEAD 2>/dev/null || echo 'no-commits-yet')"

# --- build the execution prompt ---
PROMPT="You are the code-execution stage of a plan-then-execute workflow. A stronger model already wrote and reviewed the plan; implement it faithfully — do not redesign it.

Implement the approved plan in this file:
  ${PLAN_ABS}

Rules:
- Follow the repository's AGENTS.md / CLAUDE.md conventions if present.
- Make only the changes the plan specifies. Do not refactor unrelated code or add unrequested features.
- If the project has tests, run them and make them pass.
- Do NOT commit, push, or alter git history — leave all changes in the working tree for review.
- End with a short summary of what you changed and anything the plan missed or got wrong."
if [ -n "$EXTRA" ]; then
  PROMPT="${PROMPT}

Additional instructions from the planner:
${EXTRA}"
fi

printf '=== routing-mode -> Codex ===\n'
printf 'model=%s  effort=%s  sandbox=%s\n'   "$MODEL" "$EFFORT" "$SANDBOX"
printf 'plan=%s\n\n' "$PLAN_ABS"

# --- delegate execution to Codex (non-interactive) ---
set +e
# stdin from /dev/null: codex reads stdin in non-interactive contexts (no TTY),
# and an open-but-empty stdin never reaches EOF, so it would hang forever.
# The prompt is passed as an argument, so we never need stdin.
codex exec -m "$MODEL" -s "$SANDBOX" -c model_reasoning_effort="$EFFORT" "$PROMPT" </dev/null
CODEX_RC=$?
set -e

# --- emit the changes for Claude to verify ---
printf '\n=== routing-mode: review (changes since %s) ===\n' "$BEFORE"
git --no-pager status --short || true
printf '\n--- tracked diff ---\n'
git --no-pager diff || true
UNTRACKED="$(git ls-files --others --exclude-standard || true)"
if [ -n "$UNTRACKED" ]; then
  printf '\n--- new untracked files (read them to review) ---\n%s\n' "$UNTRACKED"
fi

printf '\n=== routing-mode: Codex exit code %s ===\n' "$CODEX_RC"
exit "$CODEX_RC"
