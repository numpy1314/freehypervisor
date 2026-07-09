#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=/home/bullet1517/freehypervisor
KERNEL_DIR="$ROOT_DIR/linux-host-kernel"
BUILD_DIR="${BUILD_DIR:-$KERNEL_DIR/build-axvisor}"
LOCK_FILE="${LOCK_FILE:-$BUILD_DIR/.axvisor-build.lock}"

mkdir -p "$BUILD_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "another axvisor build is already using $BUILD_DIR" >&2
    exit 1
fi

cd "$KERNEL_DIR"

COMMON_ENV=(
    PATH=/nix/store/wfjvqf9zlh05w0admf7x1mz0jn4bfy21-llvm-21.1.8/bin:/nix/store/pjlw516aqj888w9j0z2249n8yzbnbn4x-lld-21.1.8/bin:/nix/store/wcwr4iq7c8f4ygn8bd1q0k3i51lmhz35-clang-21.1.8/bin:/nix/store/7av2pli48lhqvdwzvvxv7sdlgrmz04l4-rust-bindgen-0.72.1/bin:/home/bullet1517/.cargo/bin:/home/bullet1517/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
    RUSTUP_TOOLCHAIN=nightly-2026-04-03
    BINDGEN=/nix/store/7av2pli48lhqvdwzvvxv7sdlgrmz04l4-rust-bindgen-0.72.1/bin/bindgen
    LIBCLANG_PATH=/nix/store/jdgw7h0g0l8clmcasaspxnx6v62jz1il-clang-21.1.8-lib/lib
    RUST_LIB_SRC=/home/bullet1517/.rustup/toolchains/nightly-2026-04-03-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library
    CLANG=/nix/store/wcwr4iq7c8f4ygn8bd1q0k3i51lmhz35-clang-21.1.8/bin/clang
)

MAKE_ARGS=(
    ARCH=riscv
    CROSS_COMPILE=riscv64-linux-gnu-
    LLVM=1
    HOSTCC=gcc
    HOSTCXX=g++
    HOSTLD=gcc
    O="$BUILD_DIR"
)

env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" olddefconfig
env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" drivers/virt/axvisor/axvisor_kvm.ko -j1

stat -c '%y %n' "$BUILD_DIR/drivers/virt/axvisor/axvisor_kvm.ko"
