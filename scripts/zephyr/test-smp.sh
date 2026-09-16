#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
fh_require_nested_tcg_qemu

iterations="${FH_SMP_ITERATIONS:-20}"
"$FH_REPO_ROOT/scripts/zephyr/build.sh" smp
: > "$FH_ARTIFACTS/smp.log"

for iteration in $(seq 1 "$iterations"); do
    iteration_log="$FH_ARTIFACTS/smp-stress-$(printf '%02d' "$iteration").log"
    fh_run_qemu "$FH_BUILD_ROOT/smp/zephyr/zephyr.elf" "$iteration_log" max tcg >/dev/null
    grep -q 'FH_RESULT core-static result=PASS' "$iteration_log"
    test "$(grep -c 'succeeded to turn off SVM' "$iteration_log")" -eq 2
    for vm_id in 1 2 3 4; do
        grep -q "Creating VM\[$vm_id\]" "$iteration_log"
        stats="$(grep "FH_TASK_STATS .*name=VM\[$vm_id\]-VCpu\[0\] run=1 exit=1" \
            "$iteration_log")"
        grep -q "VM\[$vm_id\] run VCpu\[0\] SystemDown" "$iteration_log"
        block_count="$(sed -n 's/.* block=\([0-9][0-9]*\).*/\1/p' <<<"$stats")"
        wake_count="$(sed -n 's/.* wake=\([0-9][0-9]*\).*/\1/p' <<<"$stats")"
        printf 'iteration=%d vm=%d vcpu=0 run=1 exit=1 block=%s wake=%s progress=1 result=PASS\n' \
            "$iteration" "$vm_id" "$block_count" "$wake_count" \
            | tee -a "$FH_ARTIFACTS/smp.log"
    done
    # run_static_mode returns only after its four configured VMs have stopped.
    printf 'iteration=%d vcpus=4 pcpus=2 completed=4 result=PASS\n' \
        "$iteration" | tee -a "$FH_ARTIFACTS/smp.log"
done

echo "FH_SMP_RESULT=PASS" | tee -a "$FH_ARTIFACTS/smp.log"
