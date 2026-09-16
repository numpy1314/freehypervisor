#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$FH_REPO_ROOT/scripts/zephyr/build.sh" lifetime
log="$FH_ARTIFACTS/lifetime-tests.log"
fh_run_qemu "$FH_BUILD_ROOT/lifetime/zephyr/zephyr.elf" "$log"
grep -q 'FH_RESULT lifetime result=PASS' "$log"
grep -q 'FH_TEST deliberately-broken lost-wake negative-control PASS' "$log"
echo "lifetime tests PASS"
