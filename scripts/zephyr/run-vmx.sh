#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

set +e
"$FH_REPO_ROOT/scripts/zephyr/probe-hardware.sh"
probe_status=$?
set -e

if [[ "$probe_status" -eq 2 ]]; then
    {
        cat "$FH_ARTIFACTS/hardware-capability.log"
        echo "FH_VMX_RESULT=BLOCKED reason=/dev/kvm-unavailable"
    } > "$FH_ARTIFACTS/vmx-probe.log"
    {
        cat "$FH_ARTIFACTS/vmx-probe.log"
        echo "FH_VMX_VM_ENTRY_RESULT=BLOCKED reason=/dev/kvm-unavailable"
    } > "$FH_ARTIFACTS/vmx-single-vcpu.log"
    cat "$FH_ARTIFACTS/vmx-probe.log"
    exit 2
fi

if ! grep -q '^host_vmx=yes$' "$FH_ARTIFACTS/hardware-capability.log"; then
    {
        cat "$FH_ARTIFACTS/hardware-capability.log"
        echo "FH_VMX_RESULT=BLOCKED reason=host-cpuid-no-vmx"
    } > "$FH_ARTIFACTS/vmx-probe.log"
    {
        cat "$FH_ARTIFACTS/vmx-probe.log"
        echo "FH_VMX_VM_ENTRY_RESULT=BLOCKED reason=host-cpuid-no-vmx"
    } > "$FH_ARTIFACTS/vmx-single-vcpu.log"
    cat "$FH_ARTIFACTS/vmx-probe.log"
    exit 2
fi

echo "FH_VMX_RESULT=NOT_IMPLEMENTED reason=zephyr-port-selected-existing-svm-core-backend" | tee "$FH_ARTIFACTS/vmx-probe.log"
{
    cat "$FH_ARTIFACTS/vmx-probe.log"
    echo "FH_VMX_VM_ENTRY_RESULT=NOT_RUN reason=zephyr-port-selected-existing-svm-core-backend"
} > "$FH_ARTIFACTS/vmx-single-vcpu.log"
exit 2
