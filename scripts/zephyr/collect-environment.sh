#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

environment_log="$FH_ARTIFACTS/environment.txt"
versions_log="$FH_ARTIFACTS/versions.txt"

{
    echo "collected_at=$(date -u +%FT%TZ)"
    echo "uname=$(uname -a)"
    echo "cpu_count=$(nproc)"
    echo "cpu_vendor=$(awk -F: '/vendor_id/{gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
    echo "cpu_model=$(awk -F: '/model name/{gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
    echo "cpuid_vmx=$(awk -F: '/^flags/{print " "$2" "; exit}' /proc/cpuinfo | grep -qw vmx && echo yes || echo no)"
    echo "cpuid_svm=$(awk -F: '/^flags/{print " "$2" "; exit}' /proc/cpuinfo | grep -qw svm && echo yes || echo no)"
    [[ -c /dev/kvm ]] && echo "dev_kvm=yes" || echo "dev_kvm=no"
    for state in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
        if [[ -r "$state" ]]; then
            echo "$(basename "$(dirname "$state")")_nested=$(cat "$state")"
        fi
    done
} > "$environment_log"

{
    echo "freehypervisor=$(git -C "$FH_REPO_ROOT" rev-parse HEAD)"
    echo "linux_host=$(git -C "$FH_REPO_ROOT/linux-host-kernel" rev-parse HEAD)"
    echo "core=$FH_CORE_COMMIT"
    echo "asterinas_reference=68226d2303136dc8bf851937087f4a8c61748575"
    echo "zephyr=$(git -C "$FH_ZEPHYR_BASE" rev-parse HEAD)"
    echo "zephyr_toolchain_variant=$ZEPHYR_TOOLCHAIN_VARIANT"
    echo "zephyr_sdk=not-used-host-toolchain"
    echo "qemu_binary=$FH_QEMU"
    echo "qemu=$($FH_QEMU --version | head -1)"
    if [[ -f "$FH_BUILD_ROOT/qemu-tcg/freehypervisor-build.txt" ]]; then
        sed 's/^/qemu_tcg_/' "$FH_BUILD_ROOT/qemu-tcg/freehypervisor-build.txt"
    fi
    echo "rust=$(rustc +nightly-2026-05-28 --version)"
    echo "cargo=$(cargo +nightly-2026-05-28 --version)"
    echo "cc=$(cc --version | head -1)"
    echo "cmake=$(cmake --version | head -1)"
    echo "ninja=$(ninja --version)"
    echo "west=$($FH_WEST --version)"
} > "$versions_log"

git -C "$FH_ZEPHYR_BASE" rev-parse HEAD > "$FH_ARTIFACTS/zephyr-commit.txt"
git -C "$FH_REPO_ROOT" rev-parse HEAD > "$FH_ARTIFACTS/freehypervisor-commit.txt"
cat "$environment_log"
cat "$versions_log"
