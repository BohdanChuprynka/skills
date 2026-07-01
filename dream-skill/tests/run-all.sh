#!/usr/bin/env bash
# Run the LIVE on-demand-pipeline test suite, in dependency order:
#   FIND → MAP → REDUCE → ROUTE → RECONCILE → REVIEW → APPLY → RECEIPT → MARKER
#
# This manifest exists so "all tests green" measures the SHIPPED pipeline, not
# abandoned v0.2 code (see REVIEW-2026-06-04 I5). Deliberately EXCLUDED:
#   - test_preprocess.sh / test_preprocess_gate.sh / test_report.sh
#       → cover demoted v0.2 scripts (REDESIGN §5 "demote, don't delete"); kept on
#         disk but NOT part of the on-demand pipeline.
#   (test_check_pending.sh is now in LIVE_TESTS — it tests the last-run nudge hook)
# (test_trigger.sh and test_e2e.sh were deleted — they tested the dropped SessionEnd
#  trigger→preprocess auto-chain.)
#
# Run those excluded suites manually if you touch the demoted scripts.
set -uo pipefail
cd "$(dirname "$0")"

LIVE_TESTS=(
  test_check_pending.sh      # SessionStart nudge hook
  test_find_chats.sh         # FIND
  test_prefilter_transcript.sh # MAP prefilter (raw JSONL -> compact text)
  test_build_map_batches.sh  # MAP units (single-Read chunks/bundles; anti-multiplier)
  test_map_prefilter_contract.sh # MAP prompt contract for single-Read unit usage
  test_map_harness.sh        # MAP   (validate_candidates harness)
  test_reduce_dedup.sh       # REDUCE (exact + conservative TF-IDF near-dup)
  test_build_nav_context.sh  # ROUTE (nav-context builder)
  test_routing_contract.sh   # ROUTE (routing supplement + static prompt contract)
  test_batch_route.sh        # ROUTE (stable-ID batching + validation)
  test_batch_reconcile.sh    # RECONCILE (page grouping + validation)
  test_vault_writer.sh       # APPLY (write + --mode + --dry-run)
  test_path_guard.sh         # APPLY safety (vault-root confinement)
  test_apply_decision.sh     # APPLY (action→mode→writer/queue mapping)
  test_queue.sh              # REVIEW queue
  test_undo.sh               # undo / rollback
  test_write_receipt.sh      # RECEIPT
  test_private_state.sh      # FIND  private (--ignore) resolution
  test_private_guard.sh      # private opt-out guard
  test_advance_marker.sh     # MARKER advance (dry-run no-op, I3)
  test_setup.sh              # INSTALL (Claude symlink + Codex self-contained copy)
  test_integration_smoke.sh  # E2E: FIND → apply(dry-run) → receipt
)

# NOTE: REDUCE (SKILL.md Step 3) and the ROUTE/RECONCILE prompts themselves are
# LLM/orchestrator steps validated by golden fixtures. The batch builders and
# validators are executable shell suites above.

pass=0; fail=0; failed=()
LOG="$(mktemp /tmp/dream-runall-XXXXXX.log)"
trap 'rm -f "$LOG"' EXIT

for t in "${LIVE_TESTS[@]}"; do
  if [ ! -f "$t" ]; then
    echo "MISSING  $t"; fail=$((fail+1)); failed+=("$t (missing)"); continue
  fi
  if bash "$t" >"$LOG" 2>&1; then
    echo "ok       $t"
    pass=$((pass+1))
  else
    echo "FAIL     $t"
    sed 's/^/         /' "$LOG" | tail -15
    fail=$((fail+1)); failed+=("$t")
  fi
done

echo
echo "live-pipeline suites: ${pass} passed, ${fail} failed"
if [ "$fail" -ne 0 ]; then
  printf '  failed: %s\n' "${failed[@]}"
  exit 1
fi
echo "ALL LIVE-PIPELINE TESTS GREEN"
