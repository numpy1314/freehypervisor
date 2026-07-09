#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REGRESSION_ID="${REGRESSION_ID:-$(date +%Y%m%d-%H%M%S)}"
REGRESSION_DIR="${REGRESSION_DIR:-/tmp/axvisor-x86-linux-host-linux-regression.$REGRESSION_ID}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
ROOTFS_REPEAT="${ROOTFS_REPEAT:-3}"
RUN_INITRAMFS="${RUN_INITRAMFS:-1}"
SKIP_BUILD_AFTER_FIRST="${SKIP_BUILD_AFTER_FIRST:-1}"
SUMMARY="$REGRESSION_DIR/summary.txt"

run_smoke_case() {
    local name="$1"
    local boot_mode="$2"
    local skip_build="$3"
    local guest_rootfs_size="$4"
    local run_dir="$REGRESSION_DIR/$name"
    local out="$REGRESSION_DIR/$name.out"

    mkdir -p "$run_dir"
    echo "[regression] run $name boot_mode=$boot_mode skip_build=$skip_build guest_rootfs_size=$guest_rootfs_size"
    {
        echo "CASE=$name"
        echo "BOOT_MODE=$boot_mode"
        echo "RUN_DIR=$run_dir"
        echo "OUT=$out"
        echo "QEMU_LOG=$run_dir/qemu.log"
    } >>"$SUMMARY"

    RUN_DIR="$run_dir" \
    X86_GUEST_BOOT_MODE="$boot_mode" \
    SKIP_BUILD="$skip_build" \
    TIMEOUT_SECS="$TIMEOUT_SECS" \
    GUEST_ROOTFS_SIZE="$guest_rootfs_size" \
        bash "$ROOT_DIR/tools/verify-x86-linux-host-linux-smoke.sh" 2>&1 | tee "$out"

    if [[ "$boot_mode" == "rootfs" ]]; then
        echo "RESULT=$run_dir/result.txt" >>"$SUMMARY"
    fi
    echo "STATUS=pass" >>"$SUMMARY"
    echo >>"$SUMMARY"
}

mkdir -p "$REGRESSION_DIR"
: >"$SUMMARY"

echo "[regression] id=$REGRESSION_ID"
echo "[regression] dir=$REGRESSION_DIR"
echo "REGRESSION_ID=$REGRESSION_ID" >>"$SUMMARY"
echo "REGRESSION_DIR=$REGRESSION_DIR" >>"$SUMMARY"
echo "ROOTFS_REPEAT=$ROOTFS_REPEAT" >>"$SUMMARY"
echo "RUN_INITRAMFS=$RUN_INITRAMFS" >>"$SUMMARY"
echo >>"$SUMMARY"

for i in $(seq 1 "$ROOTFS_REPEAT"); do
    skip_build="$SKIP_BUILD_AFTER_FIRST"
    if [[ "$i" == "1" ]]; then
        skip_build=0
    fi
    case "$i" in
        1) rootfs_size=64M ;;
        2) rootfs_size=96M ;;
        *) rootfs_size=64M ;;
    esac
    run_smoke_case "rootfs-$i" rootfs "$skip_build" "$rootfs_size"
done

if [[ "$RUN_INITRAMFS" == "1" ]]; then
    run_smoke_case "initramfs" initramfs "$SKIP_BUILD_AFTER_FIRST" 64M
fi

echo "[regression] pass"
echo "[regression] summary: $SUMMARY"
