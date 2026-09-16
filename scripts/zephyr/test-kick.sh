#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
fh_require_nested_tcg_qemu

"$FH_REPO_ROOT/scripts/zephyr/build.sh" kick
log="$FH_ARTIFACTS/svm-kick-tcg.log"
fh_run_qemu "$FH_BUILD_ROOT/kick/zephyr/zephyr.elf" "$log" max tcg
grep -q 'FH_RESULT inguest-ipi result=PASS' "$log"
grep -q 'FH_KICK count=.*result=PASS' "$log"
test "$(grep -c 'succeeded to turn off SVM' "$log")" -eq 2
guest_enter_line="$(grep -n '1213614897' "$log" | head -1 | cut -d: -f1)"
ipi_line="$(grep -n 'dedicated IPI vector=.*count=' "$log" | head -1 | cut -d: -f1)"
guest_resume_line="$(grep -n '1263686477' "$log" | head -1 | cut -d: -f1)"
if (( guest_enter_line >= ipi_line || ipi_line >= guest_resume_line )); then
    echo "IPI did not occur inside the guest marker window" >&2
    exit 1
fi
echo "FH_KICK_WINDOW enter_line=$guest_enter_line ipi_line=$ipi_line resume_line=$guest_resume_line result=PASS" | tee -a "$log"
echo "directed in-guest IPI PASS"
