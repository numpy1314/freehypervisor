#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
fh_require_nested_tcg_qemu

"$FH_REPO_ROOT/scripts/zephyr/build.sh" probe
probe_log="$FH_ARTIFACTS/svm-probe-tcg.log"
fh_run_qemu "$FH_BUILD_ROOT/probe/zephyr/zephyr.elf" "$probe_log" max tcg
grep -q 'FH_RESULT svm-probe result=PASS' "$probe_log"

"$FH_REPO_ROOT/scripts/zephyr/build.sh" core
run_log="$FH_ARTIFACTS/svm-single-vcpu-tcg.log"
fh_run_qemu "$FH_BUILD_ROOT/core/zephyr/zephyr.elf" "$run_log" max tcg
grep -q 'FH_RESULT core-static result=PASS' "$run_log"
grep -q '1213615409' "$run_log"
grep -q '1381190961' "$run_log"
grep -q '1381190962' "$run_log"
grep -q 'SystemDown' "$run_log"
test "$(grep -c 'succeeded to turn off SVM' "$run_log")" -eq 2
grep -q 'All cores have disabled hardware virtualization support' "$run_log"
echo "TCG SVM guest PASS"
