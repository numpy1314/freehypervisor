#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$FH_REPO_ROOT/scripts/zephyr/build.sh" contract
log="$FH_ARTIFACTS/contract-tests.log"
fh_run_qemu "$FH_BUILD_ROOT/contract/zephyr/zephyr.elf" "$log"
grep -q 'FH_RESULT contract result=PASS' "$log"
echo "contract tests PASS"
