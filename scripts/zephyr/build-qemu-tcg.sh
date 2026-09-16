#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

qemu_commit="11aa0b1ff115b86160c4d37e7c37e6a6b13b77ea"
source_dir="${FH_QEMU_SOURCE:-$FH_BUILD_ROOT/qemu-8.2.2-source}"
build_dir="$FH_BUILD_ROOT/qemu-tcg"
patch_file="$FH_REPO_ROOT/ports/zephyr/qemu/0001-tcg-svm-apply-npt-to-nonpaging-guests.patch"

if [[ ! -d "$source_dir/.git" ]]; then
    git clone --filter=blob:none --no-checkout https://github.com/qemu/qemu.git "$source_dir"
    git -C "$source_dir" fetch --depth 1 origin "$qemu_commit"
    git -C "$source_dir" checkout --detach "$qemu_commit"
fi

actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$qemu_commit" ]]; then
    echo "unexpected QEMU commit: $actual_commit" >&2
    exit 1
fi

if git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "QEMU TCG NPT patch already applied"
elif git -C "$source_dir" apply --check "$patch_file"; then
    git -C "$source_dir" apply "$patch_file"
    echo "applied QEMU TCG NPT patch"
else
    echo "QEMU source has changes incompatible with the required patch" >&2
    exit 1
fi

if ! pkg-config --exists glib-2.0 pixman-1; then
    echo "QEMU build requires the glib-2.0 and pixman-1 development packages" >&2
    exit 1
fi

mkdir -p "$build_dir"
if [[ ! -f "$build_dir/build.ninja" ]]; then
    (
        cd "$build_dir"
        "$source_dir/configure" \
            --target-list=x86_64-softmmu \
            --without-default-features \
            --enable-system \
            --enable-tcg \
            --enable-pixman \
            --disable-werror
    )
fi
ninja -C "$build_dir" qemu-system-x86_64
fh_require_file "$build_dir/qemu-system-x86_64"
{
    echo "qemu_commit=$qemu_commit"
    echo "patch=$(basename "$patch_file")"
    "$build_dir/qemu-system-x86_64" --version | head -1
} > "$build_dir/freehypervisor-build.txt"
echo "$build_dir/qemu-system-x86_64"
