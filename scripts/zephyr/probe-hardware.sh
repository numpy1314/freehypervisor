#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

log="$FH_ARTIFACTS/hardware-capability.log"
{
    echo "date=$(date -u +%FT%TZ)"
    echo "arch=$(uname -m)"
    echo "kernel=$(uname -srmo)"
    if [[ -r /proc/cpuinfo ]]; then
        echo "vendor=$(awk -F: '/vendor_id/{gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
        echo "model=$(awk -F: '/model name/{gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
        flags="$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)"
        [[ " $flags " == *" vmx "* ]] && echo "host_vmx=yes" || echo "host_vmx=no"
        [[ " $flags " == *" svm "* ]] && echo "host_svm=yes" || echo "host_svm=no"
    fi
    if [[ -c /dev/kvm ]]; then
        echo "dev_kvm=yes"
        [[ -r /dev/kvm && -w /dev/kvm ]] && echo "dev_kvm_access=yes" || echo "dev_kvm_access=no"
    else
        echo "dev_kvm=no"
    fi
    for state in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
        if [[ -r "$state" ]]; then
            echo "$(basename "$(dirname "$state")")_nested=$(cat "$state")"
        fi
    done
} | tee "$log"

if [[ ! -c /dev/kvm ]]; then
    echo "FH_NATIVE_ACCEL_RESULT=BLOCKED reason=/dev/kvm-unavailable" | tee -a "$log"
    exit 2
fi
