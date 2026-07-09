#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$ROOT_DIR/linux-host-kernel"
BUILD_DIR="${BUILD_DIR:-/tmp/axvisor-adapter-x86-build}"
LOCK_FILE="${LOCK_FILE:-$BUILD_DIR/.axvisor-adapter-x86-build.lock}"
AXVISOR_ADAPTER_BUILD_BZIMAGE="${AXVISOR_ADAPTER_BUILD_BZIMAGE:-0}"
AXVISOR_LINUX_VM_CONFIG="${AXVISOR_LINUX_VM_CONFIG:-$ROOT_DIR/tools/x86_64-linux-host-vm.toml}"
AXVISOR_LINUX_GUEST_KERNEL="${AXVISOR_LINUX_GUEST_KERNEL:-$BUILD_DIR/arch/x86/boot/bzImage}"
AXVISOR_LINUX_GUEST_INITRAMFS="${AXVISOR_LINUX_GUEST_INITRAMFS:-}"

mkdir -p "$BUILD_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "another axvisor adapter build is already using $BUILD_DIR" >&2
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
    --enable RUST \
    --disable KVM \
    --disable KVM_INTEL \
    --disable KVM_AMD \
    --disable AXVISOR_KVM \
    --disable AXVISOR_KVM_AXVISOR_BACKEND \
    --disable AXVISOR_KVM_RUST_BACKEND \
    --disable AXVISOR_KVM_X86_BRIDGE \
    --disable AXVISOR_ADAPTER \
    --disable X86_KERNEL_IBT

if [[ "$AXVISOR_ADAPTER_BUILD_BZIMAGE" == "1" ]]; then
    env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" olddefconfig
    env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" bzImage -j"$(nproc)"
fi

scripts/config --file "$BUILD_DIR/.config" \
    --enable MODULES \
    --enable VIRT_DRIVERS \
    --enable RUST \
    --module AXVISOR_ADAPTER \
    --disable AXVISOR_KVM \
    --disable KVM \
    --disable KVM_INTEL \
    --disable KVM_AMD \
    --disable X86_KERNEL_IBT

env "${COMMON_ENV[@]}" make "${MAKE_ARGS[@]}" olddefconfig

MAKE_ENV=(
    "${COMMON_ENV[@]}"
    AXVISOR_LINUX_VM_CONFIG="$AXVISOR_LINUX_VM_CONFIG"
    AXVISOR_LINUX_GUEST_KERNEL="$AXVISOR_LINUX_GUEST_KERNEL"
    AXVISOR_LINUX_GUEST_DTB=
)

if [[ -n "$AXVISOR_LINUX_GUEST_INITRAMFS" ]]; then
    MAKE_ENV+=(
        AXVISOR_LINUX_GUEST_INITRAMFS="$AXVISOR_LINUX_GUEST_INITRAMFS"
        AXVISOR_LINUX_EMBED_INITRAMFS=1
    )
fi

env "${MAKE_ENV[@]}" make "${MAKE_ARGS[@]}" \
    KBUILD_MODPOST_WARN=1 \
    drivers/virt/axvisor/axvisor_adapter.ko -j1

stat -c '%y %n' "$BUILD_DIR/drivers/virt/axvisor/axvisor_adapter.ko"
if [[ "$AXVISOR_ADAPTER_BUILD_BZIMAGE" == "1" ]]; then
    stat -c '%y %n' "$BUILD_DIR/arch/x86/boot/bzImage"
fi
