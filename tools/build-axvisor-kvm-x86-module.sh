#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=/home/bullet1517/freehypervisor
KERNEL_DIR="$ROOT_DIR/linux-host-kernel"
BUILD_DIR="${BUILD_DIR:-$KERNEL_DIR/build-axvisor-kvm-x86_64}"
LOCK_FILE="${LOCK_FILE:-$BUILD_DIR/.axvisor-build.lock}"
AXVISOR_KVM_BACKEND="${AXVISOR_KVM_BACKEND:-0}"
AXVISOR_KVM_RUST_BACKEND="${AXVISOR_KVM_RUST_BACKEND:-0}"
AXVISOR_KVM_X86_BRIDGE="${AXVISOR_KVM_X86_BRIDGE:-0}"
AXVISOR_KVM_BUILD_BZIMAGE="${AXVISOR_KVM_BUILD_BZIMAGE:-0}"

mkdir -p "$BUILD_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "another axvisor kvm build is already using $BUILD_DIR" >&2
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
    ARCH=x86_64
    LLVM=1
    HOSTCC=gcc
    HOSTCXX=g++
    HOSTLD=gcc
    O="$BUILD_DIR"
)

env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" x86_64_defconfig

scripts/config --file "$BUILD_DIR/.config" \
    --enable MODULES \
    --enable VIRT_DRIVERS \
    --enable VIRTIO_MMIO \
    --enable VIRTIO_MMIO_CMDLINE_DEVICES \
    --enable VIRTIO_BLK \
    --disable AXVISOR_ADAPTER \
    --disable AXVISOR_KVM \
    --disable AXVISOR_KVM_AXVISOR_BACKEND \
    --disable AXVISOR_KVM_RUST_BACKEND \
    --disable AXVISOR_KVM_X86_BRIDGE \
    --disable KVM \
    --disable KVM_INTEL \
    --disable KVM_AMD

if [[ "$AXVISOR_KVM_BUILD_BZIMAGE" == "1" ]]; then
    env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" olddefconfig
    env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" bzImage -j"$(nproc)"
fi

scripts/config --file "$BUILD_DIR/.config" \
    --enable MODULES \
    --enable VIRT_DRIVERS \
    --disable AXVISOR_ADAPTER \
    --module AXVISOR_KVM \
    --disable KVM \
    --disable KVM_INTEL \
    --disable KVM_AMD

if [[ "$AXVISOR_KVM_BACKEND" == "1" ]]; then
    scripts/config --file "$BUILD_DIR/.config" \
        --enable AXVISOR_KVM_AXVISOR_BACKEND
else
    scripts/config --file "$BUILD_DIR/.config" \
        --disable AXVISOR_KVM_AXVISOR_BACKEND
fi

if [[ "$AXVISOR_KVM_RUST_BACKEND" == "1" ]]; then
    scripts/config --file "$BUILD_DIR/.config" \
        --enable RUST \
        --enable AXVISOR_KVM_AXVISOR_BACKEND \
        --enable AXVISOR_KVM_RUST_BACKEND \
        --disable AXVISOR_KVM_X86_BRIDGE
else
    scripts/config --file "$BUILD_DIR/.config" \
        --disable AXVISOR_KVM_RUST_BACKEND
fi

if [[ "$AXVISOR_KVM_X86_BRIDGE" == "1" ]]; then
    scripts/config --file "$BUILD_DIR/.config" \
        --enable RUST \
        --enable AXVISOR_KVM_AXVISOR_BACKEND \
        --disable AXVISOR_KVM_RUST_BACKEND \
        --enable AXVISOR_KVM_X86_BRIDGE \
        --disable X86_KERNEL_IBT
else
    scripts/config --file "$BUILD_DIR/.config" \
        --disable AXVISOR_KVM_X86_BRIDGE
fi

env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" olddefconfig
env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" KBUILD_MODPOST_WARN=1 drivers/virt/axvisor/axvisor_kvm.ko -j1

stat -c '%y %n' "$BUILD_DIR/drivers/virt/axvisor/axvisor_kvm.ko"
if [[ "$AXVISOR_KVM_BUILD_BZIMAGE" == "1" ]]; then
    stat -c '%y %n' "$BUILD_DIR/arch/x86/boot/bzImage"
fi
