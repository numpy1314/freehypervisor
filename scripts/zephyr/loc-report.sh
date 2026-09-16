#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

report="$FH_ARTIFACTS/loc-report.txt"
core_tree="$FH_BUILD_ROOT/core-src-audited"
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

"$FH_REPO_ROOT/scripts/zephyr/prepare-core.sh" >/dev/null
core_modified_files="$(git -C "$core_tree" diff --name-only | wc -l)"
read -r core_added_lines core_removed_lines < <(
    git -C "$core_tree" diff --numstat |
        awk '{ added += $1; removed += $2 } END { print added + 0, removed + 0 }'
)
core_net_lines=$((core_added_lines - core_removed_lines))
core_patches="$(find "$FH_REPO_ROOT/ports/zephyr/patches" -maxdepth 1 \
    -type f -name '*.patch' -printf '%f\n' | sort | paste -sd, -)"
qemu_patches="$(find "$FH_REPO_ROOT/ports/zephyr/qemu" -maxdepth 1 \
    -type f -name '*.patch' -printf '%f\n' | sort | paste -sd, -)"

{
    echo "core_modified_files=$core_modified_files"
    echo "core_added_lines=$core_added_lines"
    echo "core_removed_lines=$core_removed_lines"
    echo "core_net_lines=$core_net_lines"
    echo "zephyr_kernel_modified_files=0"
    echo "zephyr_kernel_modified_lines=0"
    echo "adapter_loc=$(cd "$FH_REPO_ROOT" && count_lines "${adapter_files[@]}")"
    echo "build_test_integration_loc=$(cd "$FH_REPO_ROOT" && count_lines "${integration_files[@]}")"
    echo "core_patches=$core_patches"
    echo "qemu_tcg_patches=$qemu_patches"
} > "$report"
cat "$report"
