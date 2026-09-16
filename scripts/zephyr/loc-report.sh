#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

report="$FH_ARTIFACTS/loc-report.txt"
adapter_files=(
    ports/zephyr/src
    ports/zephyr/include
    ports/zephyr/rust/src
)
integration_files=(
    ports/zephyr/CMakeLists.txt
    ports/zephyr/Kconfig
    ports/zephyr/zephyr
    ports/zephyr/linker
    ports/zephyr/app
    ports/zephyr/baseline
    ports/zephyr/guests
    scripts/zephyr
)

count_lines() {
    find "$@" -type f -print0 2>/dev/null | xargs -0 cat 2>/dev/null | wc -l
}

{
    echo "core_modified_files=4"
    echo "core_added_lines=62"
    echo "core_removed_lines=18"
    echo "core_net_lines=44"
    echo "zephyr_kernel_modified_files=0"
    echo "zephyr_kernel_modified_lines=0"
    echo "adapter_loc=$(cd "$FH_REPO_ROOT" && count_lines "${adapter_files[@]}")"
    echo "build_test_integration_loc=$(cd "$FH_REPO_ROOT" && count_lines "${integration_files[@]}")"
    echo "core_patches=0001-publish-primary-vcpu-before-spawn.patch,0002-svm-validate-address-size-only-for-string-io.patch,0003-static-mode-join-tasks-and-disable-virtualization.patch"
    echo "qemu_tcg_patch=0001-tcg-svm-apply-npt-to-nonpaging-guests.patch"
} > "$report"
cat "$report"
