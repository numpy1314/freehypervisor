#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

mode="${1:-contract}"
rust_lib=""
dts_overlay=""

case "$mode" in
    contract|lifetime|probe)
        overlay="$FH_REPO_ROOT/ports/zephyr/app/$mode.conf"
        ;;
    core)
        overlay="$FH_REPO_ROOT/ports/zephyr/app/core.conf"
        rust_lib="$("$FH_REPO_ROOT/scripts/zephyr/build-rust.sh" single | tail -1)"
        ;;
    kick)
        overlay="$FH_REPO_ROOT/ports/zephyr/app/kick.conf"
        rust_lib="$("$FH_REPO_ROOT/scripts/zephyr/build-rust.sh" kick | tail -1)"
        ;;
    smp)
        overlay="$FH_REPO_ROOT/ports/zephyr/app/core.conf"
        rust_lib="$("$FH_REPO_ROOT/scripts/zephyr/build-rust.sh" smp | tail -1)"
        ;;
    native)
        overlay="$FH_REPO_ROOT/ports/zephyr/app/core.conf"
        rust_lib="$("$FH_REPO_ROOT/scripts/zephyr/build-rust.sh" native | tail -1)"
        ;;
    linux)
        overlay="$FH_REPO_ROOT/ports/zephyr/app/linux.conf"
        dts_overlay="$FH_REPO_ROOT/ports/zephyr/app/linux.overlay"
        rust_lib="$("$FH_REPO_ROOT/scripts/zephyr/build-rust.sh" linux | tail -1)"
        ;;
    *)
        echo "usage: $0 {contract|lifetime|probe|core|kick|smp|native|linux}" >&2
        exit 1
        ;;
esac

cmake_args=(
    "-DEXTRA_CONF_FILE=$overlay"
    "-DZEPHYR_EXTRA_MODULES=$FH_REPO_ROOT/ports/zephyr"
)
if [[ -n "$rust_lib" ]]; then
    cmake_args+=("-DFREEHYPERVISOR_RUST_LIB=$rust_lib")
fi
if [[ -n "$dts_overlay" ]]; then
    cmake_args+=("-DDTC_OVERLAY_FILE=$dts_overlay")
fi

final_dir="$FH_BUILD_ROOT/$mode"
stale_root="$(mktemp -d "$FH_BUILD_ROOT/$mode.stale.XXXXXX")"
failed_root="$(mktemp -d "$FH_BUILD_ROOT/$mode.failed.XXXXXX")"
stale_dir="$stale_root/$mode"
failed_dir="$failed_root/$mode"
case "$final_dir" in
    "$FH_REPO_ROOT"/build/zephyr/*) ;;
    *) echo "refusing unsafe build path: $final_dir" >&2; exit 1 ;;
esac

if [[ -d "$final_dir" ]]; then
    mv "$final_dir" "$stale_dir"
fi
set +e
"$FH_WEST" build \
    -b qemu_x86_64 \
    -d "$final_dir" \
    "$FH_REPO_ROOT/ports/zephyr/app" \
    -- "${cmake_args[@]}"
build_status=$?
set -e
if [[ "$build_status" -ne 0 ]]; then
    if [[ -d "$final_dir" ]]; then
        mv "$final_dir" "$failed_dir"
    fi
    if [[ -d "$stale_dir" ]]; then
        mv "$stale_dir" "$final_dir"
    fi
    rm -rf "$failed_root" "$stale_root" || true
    exit "$build_status"
fi
if ! rm -rf "$stale_root" "$failed_root"; then
    echo "warning: stale Zephyr build remains under $FH_BUILD_ROOT" >&2
fi

if [[ -n "$rust_lib" ]]; then
    percpu_start="$(nm -n "$final_dir/zephyr/zephyr.elf" | awk '$3 == "_percpu_load_start" {print $1}')"
    percpu_end="$(nm -n "$final_dir/zephyr/zephyr.elf" | awk '$3 == "_percpu_load_end" {print $1}')"
    if [[ -z "$percpu_start" || -z "$percpu_end" || "$percpu_start" == "$percpu_end" ]]; then
        echo "Rust per-CPU template is absent from the final Zephyr image" >&2
        exit 1
    fi
    echo "Rust per-CPU template [$percpu_start, $percpu_end)"
fi
