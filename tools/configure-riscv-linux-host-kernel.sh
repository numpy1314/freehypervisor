#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT_DIR/linux-host-kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/build-axvisor}"
ARCH_NAME="${ARCH_NAME:-riscv}"
CROSS_COMPILE_PREFIX="${CROSS_COMPILE_PREFIX:-riscv64-linux-gnu-}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-nightly-2026-04-03}"
BASE_CONFIG_TARGET="${BASE_CONFIG_TARGET:-defconfig}"
HOSTCC_BIN="${HOSTCC_BIN:-gcc}"
HOSTCXX_BIN="${HOSTCXX_BIN:-g++}"
HOSTLD_BIN="${HOSTLD_BIN:-gcc}"
CLANG_BIN="${CLANG_BIN:-/nix/store/wcwr4iq7c8f4ygn8bd1q0k3i51lmhz35-clang-21.1.8/bin/clang}"
BINDGEN_BIN="${BINDGEN_BIN:-/nix/store/7av2pli48lhqvdwzvvxv7sdlgrmz04l4-rust-bindgen-0.72.1/bin/bindgen}"
LIBCLANG_PATH="${LIBCLANG_PATH:-/nix/store/jdgw7h0g0l8clmcasaspxnx6v62jz1il-clang-21.1.8-lib/lib}"
RUST_LIB_SRC="${RUST_LIB_SRC:-$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot)/lib/rustlib/src/rust/library}"
LLVM_BIN_DIR="${LLVM_BIN_DIR:-/nix/store/wfjvqf9zlh05w0admf7x1mz0jn4bfy21-llvm-21.1.8/bin}"
LLD_BIN_DIR="${LLD_BIN_DIR:-/nix/store/pjlw516aqj888w9j0z2249n8yzbnbn4x-lld-21.1.8/bin}"

MERGE_CONFIG_SH="$KERNEL_DIR/scripts/kconfig/merge_config.sh"
RUST_FRAGMENT="$KERNEL_DIR/kernel/configs/rust.config"
LOCAL_FRAGMENT="$OUT_DIR/axvisor-host.fragment"

need_file() {
    [[ -f "$1" ]] || {
        echo "required file not found: $1" >&2
        exit 1
    }
}

need_file "$MERGE_CONFIG_SH"
need_file "$RUST_FRAGMENT"
command -v "$HOSTCC_BIN" >/dev/null || {
    echo "required host compiler not found: $HOSTCC_BIN" >&2
    exit 1
}
command -v "$HOSTCXX_BIN" >/dev/null || {
    echo "required host c++ compiler not found: $HOSTCXX_BIN" >&2
    exit 1
}
command -v "$HOSTLD_BIN" >/dev/null || {
    echo "required host linker driver not found: $HOSTLD_BIN" >&2
    exit 1
}
need_file "$CLANG_BIN"
need_file "$BINDGEN_BIN"
[[ -d "$LLVM_BIN_DIR" ]] || {
    echo "required directory not found: $LLVM_BIN_DIR" >&2
    exit 1
}
[[ -d "$LLD_BIN_DIR" ]] || {
    echo "required directory not found: $LLD_BIN_DIR" >&2
    exit 1
}
[[ -d "$LIBCLANG_PATH" ]] || {
    echo "required directory not found: $LIBCLANG_PATH" >&2
    exit 1
}
[[ -d "$RUST_LIB_SRC" ]] || {
    echo "required directory not found: $RUST_LIB_SRC" >&2
    exit 1
}

mkdir -p "$OUT_DIR"

export PATH="$LLVM_BIN_DIR:$LLD_BIN_DIR:$(dirname "$CLANG_BIN"):$(dirname "$BINDGEN_BIN"):$PATH"

# Reinitialize the out-of-tree build directory when switching toolchains.
make -C "$KERNEL_DIR" \
    RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" \
    ARCH="$ARCH_NAME" \
    CROSS_COMPILE="$CROSS_COMPILE_PREFIX" \
    LLVM=1 \
    HOSTCC="$HOSTCC_BIN" \
    HOSTCXX="$HOSTCXX_BIN" \
    HOSTLD="$HOSTLD_BIN" \
    CLANG="$CLANG_BIN" \
    BINDGEN="$BINDGEN_BIN" \
    LIBCLANG_PATH="$LIBCLANG_PATH" \
    RUST_LIB_SRC="$RUST_LIB_SRC" \
    O="$OUT_DIR" \
    mrproper

cat >"$LOCAL_FRAGMENT" <<'EOF'
CONFIG_RUST=y
CONFIG_MODULES=y
CONFIG_VIRT_DRIVERS=y
CONFIG_AXVISOR_ADAPTER=m
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_MMIO=y
CONFIG_EXT4_FS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
EOF

make -C "$KERNEL_DIR" \
    RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" \
    ARCH="$ARCH_NAME" \
    CROSS_COMPILE="$CROSS_COMPILE_PREFIX" \
    LLVM=1 \
    HOSTCC="$HOSTCC_BIN" \
    HOSTCXX="$HOSTCXX_BIN" \
    HOSTLD="$HOSTLD_BIN" \
    CLANG="$CLANG_BIN" \
    BINDGEN="$BINDGEN_BIN" \
    LIBCLANG_PATH="$LIBCLANG_PATH" \
    RUST_LIB_SRC="$RUST_LIB_SRC" \
    O="$OUT_DIR" \
    "$BASE_CONFIG_TARGET"

(
    cd "$KERNEL_DIR"
    env RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" \
        ARCH="$ARCH_NAME" \
        CROSS_COMPILE="$CROSS_COMPILE_PREFIX" \
        LLVM=1 \
        HOSTCC="$HOSTCC_BIN" \
        HOSTCXX="$HOSTCXX_BIN" \
        HOSTLD="$HOSTLD_BIN" \
        CLANG="$CLANG_BIN" \
        BINDGEN="$BINDGEN_BIN" \
        LIBCLANG_PATH="$LIBCLANG_PATH" \
        RUST_LIB_SRC="$RUST_LIB_SRC" \
        KCONFIG_CONFIG="$OUT_DIR/.config" \
        "$MERGE_CONFIG_SH" \
        -m \
        -O "$OUT_DIR" \
        "$OUT_DIR/.config" \
        "$RUST_FRAGMENT" \
        "$LOCAL_FRAGMENT"
)

make -C "$KERNEL_DIR" \
    RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" \
    ARCH="$ARCH_NAME" \
    CROSS_COMPILE="$CROSS_COMPILE_PREFIX" \
    LLVM=1 \
    HOSTCC="$HOSTCC_BIN" \
    HOSTCXX="$HOSTCXX_BIN" \
    HOSTLD="$HOSTLD_BIN" \
    CLANG="$CLANG_BIN" \
    BINDGEN="$BINDGEN_BIN" \
    LIBCLANG_PATH="$LIBCLANG_PATH" \
    RUST_LIB_SRC="$RUST_LIB_SRC" \
    O="$OUT_DIR" \
    olddefconfig

if ! grep -q '^CONFIG_RUST=y$' "$OUT_DIR/.config"; then
    echo "failed to enable CONFIG_RUST in $OUT_DIR/.config" >&2
    exit 1
fi

echo "configured kernel output: $OUT_DIR"
grep -E '^CONFIG_RUST=|^CONFIG_MODULES=|^CONFIG_VIRT_DRIVERS=|^CONFIG_AXVISOR_ADAPTER=|^CONFIG_VIRTIO_BLK=|^CONFIG_EXT4_FS=' "$OUT_DIR/.config" || true
