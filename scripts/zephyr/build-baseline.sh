#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

final_dir="$FH_BUILD_ROOT/baseline"
stale_root="$(mktemp -d "$FH_BUILD_ROOT/baseline.stale.XXXXXX")"
failed_root="$(mktemp -d "$FH_BUILD_ROOT/baseline.failed.XXXXXX")"
stale_dir="$stale_root/baseline"
failed_dir="$failed_root/baseline"
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
    "$FH_REPO_ROOT/ports/zephyr/baseline"
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
    echo "warning: stale Zephyr baseline build remains under $FH_BUILD_ROOT" >&2
fi
