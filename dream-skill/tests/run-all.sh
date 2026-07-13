#!/usr/bin/env bash
# Run the shipped deterministic Dream pipeline suite.
set -uo pipefail
cd "$(dirname "$0")"

LIVE_TESTS=(
  test_check_pending.sh
  test_find_chats.sh
  test_build_map_batches.sh
  test_path_guard.sh
  test_queue.sh
  test_undo.sh
  test_write_freshness.sh
  test_write_receipt.sh
  test_write_density.sh
  test_private_state.sh
  test_private_guard.sh
  test_setup.sh
  test_agent_runner.sh
  test_candidate_validation.sh
  test_candidate_policy.sh
  test_cleanup_transaction.sh
  test_cross_target_conflicts.sh
  test_dream_health.sh
  test_dream_run_e2e.sh
  test_engine_backends.sh
  test_marker_gate.sh
  test_memory_tier.sh
  test_preflight.sh
  test_reconcile_context.sh
  test_reconcile_contract.sh
  test_reconcile_packing.sh
  test_reduce_provenance.sh
  test_repair_queue_state.sh
  test_review_server.sh
  test_review_feedback.sh
  test_review_queue_metadata.sh
  test_review_transaction.sh
  test_route_entities.sh
  test_route_fallback.sh
  test_route_retrieval.sh
  test_stable_ids.sh
)

pass=0
fail=0
failed=()
log="$(mktemp "${TMPDIR:-/tmp}/dream-runall.XXXXXX")"
trap 'rm -f "$log"' EXIT

for test_script in "${LIVE_TESTS[@]}"; do
  if bash "$test_script" >"$log" 2>&1; then
    echo "ok       $test_script"
    pass=$((pass + 1))
  else
    echo "FAIL     $test_script"
    sed 's/^/         /' "$log" | tail -20
    fail=$((fail + 1))
    failed+=("$test_script")
  fi
done

echo
echo "shipped suites: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  printf '  failed: %s\n' "${failed[@]}"
  exit 1
fi
echo "ALL SHIPPED TESTS GREEN"
