#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

set +e
"$FH_REPO_ROOT/scripts/zephyr/probe-hardware.sh"
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
    {
        cat "$FH_ARTIFACTS/hardware-capability.log"
        echo "FH_NATIVE_SVM_RESULT=BLOCKED reason=/dev/kvm-unavailable"
    } > "$FH_ARTIFACTS/svm-native.log"
    cat "$FH_ARTIFACTS/svm-native.log"
    exit "$status"
fi

if ! grep -q '^host_svm=yes$' "$FH_ARTIFACTS/hardware-capability.log"; then
    echo "FH_NATIVE_SVM_RESULT=BLOCKED reason=host-cpuid-no-svm" | tee "$FH_ARTIFACTS/svm-native.log"
    exit 2
fi

"$FH_REPO_ROOT/scripts/zephyr/build.sh" native
fh_run_qemu "$FH_BUILD_ROOT/native/zephyr/zephyr.elf" "$FH_ARTIFACTS/svm-native.log" host kvm
grep -q 'FH_RESULT core-static result=PASS' "$FH_ARTIFACTS/svm-native.log"
test "$(grep -c 'succeeded to turn off SVM' "$FH_ARTIFACTS/svm-native.log")" -eq 2
echo "FH_NATIVE_SVM_RESULT=PASS" | tee -a "$FH_ARTIFACTS/svm-native.log"
