#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_ID="${SUITE_ID:-$(date +%Y%m%d-%H%M%S)}"
SUITE_DIR="${SUITE_DIR:-/tmp/axvisor-x86-linux-host-linux-suite.$SUITE_ID}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
SKIP_BUILD_AFTER_FIRST="${SKIP_BUILD_AFTER_FIRST:-1}"

run_case() {
    local name="$1"
    local boot_mode="$2"
    local skip_build="$3"
    local run_dir="$SUITE_DIR/$name"
    local out="$SUITE_DIR/$name.out"

    mkdir -p "$run_dir"
    echo "[suite] run $name boot_mode=$boot_mode skip_build=$skip_build"
    RUN_DIR="$run_dir" \
    X86_GUEST_BOOT_MODE="$boot_mode" \
    SKIP_BUILD="$skip_build" \
    TIMEOUT_SECS="$TIMEOUT_SECS" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" 2>&1 | tee "$out"
}

mkdir -p "$SUITE_DIR"

run_case rootfs rootfs 0
run_case initramfs initramfs "$SKIP_BUILD_AFTER_FIRST"

echo "[suite] pass"
echo "[suite] suite dir: $SUITE_DIR"
