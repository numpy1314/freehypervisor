#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$FH_REPO_ROOT/scripts/zephyr/audit-contract.py" "$FH_CORE_SOURCE" \
    --output "$FH_ARTIFACTS/contract-inventory.tsv"
"$FH_REPO_ROOT/scripts/zephyr/run-baseline.sh"
"$FH_REPO_ROOT/scripts/zephyr/test-contract.sh"
"$FH_REPO_ROOT/scripts/zephyr/test-lifetime.sh"
"$FH_REPO_ROOT/scripts/zephyr/run-tcg-svm.sh"
"$FH_REPO_ROOT/scripts/zephyr/test-kick.sh"
"$FH_REPO_ROOT/scripts/zephyr/test-smp.sh"
"$FH_REPO_ROOT/scripts/zephyr/loc-report.sh"
"$FH_REPO_ROOT/scripts/zephyr/collect-environment.sh"

echo "FH_ZEPHYR_SOFTWARE_TEST_RESULT=PASS"
