#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$FH_REPO_ROOT/scripts/zephyr/build-baseline.sh"
log="$FH_ARTIFACTS/baseline.log"
fh_run_qemu "$FH_BUILD_ROOT/baseline/zephyr/zephyr.elf" "$log"
grep -q 'BASELINE_RESULT=PASS' "$log"
echo "baseline PASS"
